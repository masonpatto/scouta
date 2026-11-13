-- Makes the onboarding mission card's "+2,500 SC" promise real. It
-- was pure UI text -- completeOnboarding() never granted anything, and
-- no milestone matched it -- so every new user was promised a reward
-- that never arrived. This pays it out on a user's first-ever buy.
--
-- Reuses claimed_milestones exactly like every other one-time reward
-- (first_1000, first_10x, etc. -- migration 0001) rather than a new
-- mechanism: the table's own unique (user_id, milestone_key)
-- constraint makes the grant race-safe on its own (two near-
-- simultaneous first buys from the same account can't double-grant
-- it), and ON CONFLICT DO NOTHING + checking FOUND is the standard,
-- already-proven way to tell whether this specific insert actually
-- happened or hit that conflict.
--
-- Every other line below is unchanged from migration 0022 (which
-- added the share-ceiling check) -- only the reward block, placed
-- right after the buy's own transaction/activity_log rows, same
-- position sell_player already uses for its own one-time bonus.

CREATE OR REPLACE FUNCTION public.buy_player(p_player_id uuid, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_cash numeric;
  v_price numeric;
  v_fee numeric;
  v_net_invest numeric;
  v_shares_bought numeric;
  v_existing_shares numeric;
  v_existing_avg_buy numeric;
  v_existing_value numeric;
  v_portfolio_value numeric;
  v_new_position_value numeric;
  v_concentration numeric;
  v_total_cost numeric;
  v_total_shares numeric;
  v_player_name text;
  v_player_rating integer;
  v_player_age integer;
  v_tier_ceiling numeric;
  v_player_market_cap numeric;
  v_impact_recent_volume numeric;
  v_impact_dampener numeric;
  v_impact_market_cap numeric;
  v_impact_pct numeric;
  v_impact_new_price numeric;
  v_first_mission_granted boolean := false;
begin
  perform set_config('scouta.trusted_profile_update', 'true', true);

  if v_user_id is null then
    return jsonb_build_object('ok', false, 'reason', 'Not authenticated.');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'Enter an amount to invest.');
  end if;

  if p_amount < 5 then
    return jsonb_build_object('ok', false, 'reason', 'Minimum investment is 5 SC.');
  end if;

  -- Lock the profile row for the duration of this transaction, so two
  -- concurrent buy requests from the same user can't both succeed
  -- against the same cash balance.
  select cash_sc into v_cash from public.profiles where id = v_user_id for update;
  if v_cash is null then
    return jsonb_build_object('ok', false, 'reason', 'Profile not found.');
  end if;

  if p_amount > v_cash then
    return jsonb_build_object('ok', false, 'reason', 'Not enough cash SC available.');
  end if;

  select current_price, name, rating, age into v_price, v_player_name, v_player_rating, v_player_age
    from public.players where id = p_player_id;
  if v_price is null then
    return jsonb_build_object('ok', false, 'reason', 'Player not found.');
  end if;

  -- Price-impact dampener, computed now (before this trade's own
  -- transactions row exists below) so it only reflects prior activity,
  -- never this trade counting against itself.
  select coalesce(sum(amount), 0) into v_impact_recent_volume
    from public.transactions
    where user_id = v_user_id and player_id = p_player_id
      and type in ('buy', 'sell') and created_at > now() - interval '2 hours';
  v_impact_dampener := 1 / (1 + v_impact_recent_volume / 150);

  v_fee := round(p_amount * 0.02, 2);
  v_net_invest := p_amount - v_fee;
  v_shares_bought := v_net_invest / v_price;

  -- Share ceiling check: total SC invested across every holder of this
  -- player, plus what this buy would add, can't exceed its tier's
  -- ceiling. Checked against the state before this trade touches
  -- anything, so a rejected buy leaves no trace.
  select coalesce(sum(h.shares * v_price), 0) into v_player_market_cap
    from public.holdings h where h.player_id = p_player_id;
  v_tier_ceiling := public.player_tier_ceiling(v_player_rating, v_player_age);
  if v_player_market_cap + v_net_invest > v_tier_ceiling then
    return jsonb_build_object(
      'ok', false,
      'sold_out', true,
      'reason', 'Sold out -- this player''s share ceiling has been reached.'
    );
  end if;

  select coalesce(sum(h.shares * pl.current_price), 0) + v_cash
    into v_portfolio_value
    from public.holdings h
    join public.players pl on pl.id = h.player_id
    where h.user_id = v_user_id;

  -- "for update" added: without it, a concurrent full sell of this same
  -- player could delete this row between this read and the update below,
  -- silently losing the share increase while cash still gets deducted.
  select shares, avg_buy_price into v_existing_shares, v_existing_avg_buy
    from public.holdings where user_id = v_user_id and player_id = p_player_id
    for update;

  v_existing_value := coalesce(v_existing_shares, 0) * v_price;
  v_new_position_value := v_existing_value + v_net_invest;
  v_concentration := v_new_position_value / nullif(v_portfolio_value - v_fee, 0);

  if v_concentration > 0.30000001 then
    return jsonb_build_object('ok', false, 'reason', 'This would put more than 30% of your portfolio in one player.');
  end if;

  if v_existing_shares is not null then
    v_total_cost := v_existing_shares * v_existing_avg_buy + v_net_invest;
    v_total_shares := v_existing_shares + v_shares_bought;
    perform set_config('scouta.trusted_holdings_update', 'true', true);
    update public.holdings
      set shares = v_total_shares, avg_buy_price = v_total_cost / v_total_shares, updated_at = now()
      where user_id = v_user_id and player_id = p_player_id;
  else
    insert into public.holdings (user_id, player_id, shares, avg_buy_price)
    values (v_user_id, p_player_id, v_shares_bought, v_net_invest / v_shares_bought);
  end if;

  update public.profiles set cash_sc = cash_sc - p_amount where id = v_user_id;

  insert into public.transactions (user_id, player_id, type, shares, price, amount, fee)
  values (v_user_id, p_player_id, 'buy', v_shares_bought, v_price, p_amount, v_fee);

  insert into public.activity_log (user_id, type, player_id, detail)
  values (v_user_id, 'buy', p_player_id, 'Bought ' || v_player_name);

  -- First mission bonus: the onboarding card's promised +2,500 SC,
  -- paid out exactly once, the first time this account ever buys
  -- anything. See this file's header for why claimed_milestones (not
  -- a fresh check) is what makes this safe to grant exactly once.
  insert into public.claimed_milestones (user_id, milestone_key)
  values (v_user_id, 'first_mission')
  on conflict do nothing;
  v_first_mission_granted := found;

  if v_first_mission_granted then
    update public.profiles set cash_sc = cash_sc + 2500 where id = v_user_id;
    insert into public.transactions (user_id, player_id, type, amount, reason)
    values (v_user_id, p_player_id, 'reward', 2500, 'First mission: your first investment');
    insert into public.activity_log (user_id, type, player_id, detail)
    values (v_user_id, 'reward', p_player_id, 'Earned 2,500 SC — First mission complete');
  end if;

  perform public.check_milestones(v_user_id);

  -- Instant price impact: normalized by market cap, hard-capped, and
  -- damped by this account's own recent activity on this player (see
  -- migration 0020's header comment for the full reasoning).
  select greatest(500, coalesce(sum(h.shares * v_price), 0))
    into v_impact_market_cap
    from public.holdings h where h.player_id = p_player_id;
  v_impact_pct := least(2.0, (p_amount / v_impact_market_cap) * 40) * v_impact_dampener;
  if v_impact_pct > 0 then
    v_impact_new_price := greatest(10, round(v_price * (1 + v_impact_pct / 100), 2));
    perform set_config(
      'scouta.price_change_reason',
      format('Buy pressure: %s SC traded (+%s%%)', round(p_amount, 2), round(v_impact_pct, 2)),
      true
    );
    update public.players set current_price = v_impact_new_price where id = p_player_id;
  end if;

  return jsonb_build_object('ok', true, 'shares_bought', v_shares_bought, 'fee', v_fee, 'price', v_price, 'first_mission_bonus', v_first_mission_granted);
end;
$function$;
