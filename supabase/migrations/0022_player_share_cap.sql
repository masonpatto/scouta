-- A per-player "share ceiling" -- the trading-card-collectible version
-- of a real stock's limited float. Once a player's total SC invested
-- across every holder combined reaches their ceiling, buying more is
-- rejected outright: "Sold Out", same framing a limited print run uses.
--
-- Denominated in SC (total invested), not a raw share count: shares are
-- already fractional decimals (0.27 shares, etc.), so "500 shares max"
-- is an awkward thing to show a user, while "142,000 / 150,000 SC
-- invested" reads instantly and doubles as a subscription-style
-- progress bar. It also self-scales: as a player's price rises (via
-- the rating-delta or trade-impact engines), the same SC ceiling fills
-- up with fewer, pricier shares -- a popular player naturally feels
-- scarcer without any extra logic. Reuses the exact "market cap" sum
-- (sum of every holder's shares * current price) already computed for
-- the trade-impact engine (migration 0020).
--
-- The ceiling itself is tied to rarity tier, mirroring tierFor() in
-- App.js exactly (special editions -- wonderkid/veteran -- checked
-- first, then the rating ladder), not a flat number for every player:
-- the whole point is that an ELITE or WONDERKID card is genuinely
-- harder to get a piece of than a COMMON one, matching the "find them
-- before anyone else has" theme the app already leans into everywhere
-- else (the onboarding quiz, the Hidden Gems/Wonderkids Discover
-- filters). Numbers below are a reasoned starting point, not
-- empirically tuned -- expect to revisit once real trading volume
-- shows what actually fills up and what never comes close.

create or replace function public.player_tier_ceiling(p_rating integer, p_age integer)
returns numeric
language plpgsql
immutable
as $$
declare
  r integer := coalesce(p_rating, 0);
begin
  if p_age is not null and p_age <= 21 and r >= 79 then
    return 10000; -- wonderkid: scarcest of all, matches the app's whole "found first" premise
  end if;
  if p_age is not null and p_age >= 32 and r >= 81 then
    return 30000; -- veteran: respected, but not the same discovery-value as a wonderkid
  end if;
  if r >= 87 then return 15000; end if; -- elite
  if r >= 83 then return 25000; end if; -- platinum
  if r >= 79 then return 40000; end if; -- rare
  if r >= 75 then return 60000; end if; -- uncommon
  return 100000; -- common: the most available tier
end;
$$;

-- Powers the buy sheet's fill-progress display. holdings' RLS is
-- owner-scoped, same reason player_investor_count (migration 0021)
-- needed a SECURITY DEFINER wrapper rather than a plain client query.
create or replace function public.player_cap_status(p_player_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_price numeric;
  v_rating integer;
  v_age integer;
  v_market_cap numeric;
  v_ceiling numeric;
begin
  select current_price, rating, age into v_price, v_rating, v_age
    from public.players where id = p_player_id;
  if v_price is null then
    return jsonb_build_object('market_cap', 0, 'ceiling', 0, 'pct_filled', 0, 'sold_out', false);
  end if;

  select coalesce(sum(h.shares * v_price), 0) into v_market_cap
    from public.holdings h where h.player_id = p_player_id;

  v_ceiling := public.player_tier_ceiling(v_rating, v_age);

  return jsonb_build_object(
    'market_cap', round(v_market_cap, 2),
    'ceiling', v_ceiling,
    'pct_filled', round(least(100, (v_market_cap / v_ceiling) * 100), 1),
    'sold_out', v_market_cap >= v_ceiling
  );
end;
$$;

revoke all on function public.player_cap_status(uuid) from public, anon;
grant execute on function public.player_cap_status(uuid) to authenticated;

-- buy_player, extended with the cap check. Every other line is
-- unchanged from migration 0020 -- only the rating/age fetch (to look
-- up the ceiling) and the new reject-when-full check are new, inserted
-- as part of the existing validation block alongside the 30%
-- concentration check.
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

  return jsonb_build_object('ok', true, 'shares_bought', v_shares_bought, 'fee', v_fee, 'price', v_price);
end;
$function$;
