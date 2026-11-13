-- Instant demand-driven pricing: every buy nudges a player's price up
-- for whoever trades next, every sell nudges it down -- on top of (not
-- instead of) the rating-delta engine's evidence-based moves. Chosen
-- over a periodic/batched version specifically so it's visible the
-- moment a trade happens, like watching a real ticker move.
--
-- That immediacy is also exactly what makes it abusable if left
-- unguarded, so this has three separate constraints stacked together,
-- not just a single cap:
--
-- 1. Normalized by the player's own total held value ("market cap" --
--    sum of every holder's shares * price). The same 100 SC trade
--    moves a thinly-held player far more than a widely-held one, which
--    is realistic, and also means a whale needs real capital to move a
--    popular player, not just one lucky illiquid pick. Floored at 500
--    SC so a player's very first-ever trade (market cap ~0) can't
--    divide-by-near-zero into a wild swing.
-- 2. Hard-capped at +/-2% per single trade, full stop, regardless of
--    size -- deliberately tighter than the rating engine's +/-15% per
--    sync, since this fires on every trade instead of every few hours
--    and the signal is much noisier.
-- 3. Damped by how much this same account has already traded this same
--    player in the last 2 hours (v_*_recent_volume below, read from
--    transactions -- no new table needed). One big trade already costs
--    progressively less marginal impact than it looks like at first
--    (that's constraint 1), but the real risk with an instant model is
--    one account placing many SMALL trades back-to-back to walk a
--    price up gradually. This shrinks that account's impact the more
--    they've already pushed this specific player recently, smoothly
--    (no hard cutoff), so spamming small trades runs into diminishing
--    returns fast. Applied AFTER constraints 1+2 (cap the raw size/
--    market-cap signal first, then multiply by the dampener), not
--    before -- damping a value that then gets capped lets the cap
--    silently override the damping, which defeats this constraint
--    specifically on the thin/new players it matters most for.
--
-- Two things that were already true and still help: buying then
-- immediately selling nets your own holding back to ~zero while
-- costing you the 2% fee *twice* (4% round-trip, guaranteed, whatever
-- the price does in between) -- wash-trading to manufacture fake
-- momentum is a guaranteed loss, not a free action. And the existing
-- 30%-of-portfolio concentration cap (migration 0001) already limits
-- how much any single account can pile into one player in the first
-- place.
--
-- Deliberately NOT applied to what the trader themselves pays/receives
-- -- v_price is fetched once, used for this trade's own shares/proceeds
-- math exactly as before, and only AFTER that's settled does
-- current_price move for the next person. No self-slippage: what you
-- see quoted is what you pay.
--
-- This logic is inlined directly into buy_player/sell_player rather
-- than factored into a shared helper RPC on purpose -- a separate
-- function would need its own grants, and anything callable on its own
-- is something a client could call directly with a fabricated amount
-- to move a price with no real trade behind it. Inlined, the only way
-- to trigger a price move is to actually execute (and pay the fee on)
-- a real trade.

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

  select current_price, name into v_price, v_player_name
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
  -- the three constraints in this file's header comment).
  select greatest(500, coalesce(sum(h.shares * v_price), 0))
    into v_impact_market_cap
    from public.holdings h where h.player_id = p_player_id;
  -- Hard cap applies first, to the undamped size/market-cap signal, and
  -- the dampener multiplies the result AFTER that -- not before. Damping
  -- before capping let the cap mask the dampener entirely: a thin
  -- player's trades hit the 2% ceiling almost immediately regardless of
  -- size, so a dampener applied pre-cap never visibly reduced anything
  -- (caught by testing this against a real thin-market scenario before
  -- shipping it, not assumed from the formula alone).
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

CREATE OR REPLACE FUNCTION public.sell_player(p_player_id uuid, p_shares numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_existing_shares numeric;
  v_avg_buy numeric;
  v_price numeric;
  v_player_name text;
  v_gross numeric;
  v_fee numeric;
  v_net numeric;
  v_cost_basis numeric;
  v_realized_pl numeric;
  v_reward numeric;
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

  select shares, avg_buy_price into v_existing_shares, v_avg_buy
    from public.holdings where user_id = v_user_id and player_id = p_player_id
    for update;

  if v_existing_shares is null then
    return jsonb_build_object('ok', false, 'reason', 'You don''t hold this player.');
  end if;

  if p_shares is null or p_shares <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'Enter shares to sell.');
  end if;

  if p_shares > v_existing_shares + 0.000001 then
    return jsonb_build_object('ok', false, 'reason', 'You don''t own that many shares.');
  end if;

  select current_price, name into v_price, v_player_name
    from public.players where id = p_player_id;

  -- Same dampener as buy_player, computed before this trade's own
  -- transactions row exists.
  select coalesce(sum(amount), 0) into v_impact_recent_volume
    from public.transactions
    where user_id = v_user_id and player_id = p_player_id
      and type in ('buy', 'sell') and created_at > now() - interval '2 hours';
  v_impact_dampener := 1 / (1 + v_impact_recent_volume / 150);

  v_gross := p_shares * v_price;
  v_fee := round(v_gross * 0.02, 2);
  v_net := v_gross - v_fee;
  v_cost_basis := p_shares * v_avg_buy;
  v_realized_pl := v_net - v_cost_basis;

  if p_shares >= v_existing_shares - 0.000001 then
    delete from public.holdings where user_id = v_user_id and player_id = p_player_id;
  else
    perform set_config('scouta.trusted_holdings_update', 'true', true);
    update public.holdings
      set shares = shares - p_shares, updated_at = now()
      where user_id = v_user_id and player_id = p_player_id;
  end if;

  update public.profiles set cash_sc = cash_sc + v_net where id = v_user_id;

  insert into public.transactions (user_id, player_id, type, shares, price, amount, fee, profit)
  values (v_user_id, p_player_id, 'sell', p_shares, v_price, v_net, v_fee, v_realized_pl);

  insert into public.activity_log (user_id, type, player_id, detail)
  values (v_user_id, 'sell', p_player_id, 'Sold ' || v_player_name);

  -- Outcome-gated reward: a genuinely profitable sale, matching the
  -- SC Economy design -- reward outcomes, never presence.
  if v_realized_pl >= 10 then
    v_reward := least(30, round(v_realized_pl * 0.05, 2));
    update public.profiles set cash_sc = cash_sc + v_reward where id = v_user_id;
    insert into public.transactions (user_id, player_id, type, amount, reason)
    values (v_user_id, p_player_id, 'reward', v_reward, 'Profitable sale: ' || v_player_name);
    insert into public.activity_log (user_id, type, player_id, detail)
    values (v_user_id, 'reward', p_player_id, 'Earned ' || v_reward || ' SC — Profitable sale: ' || v_player_name);
  end if;

  perform public.check_milestones(v_user_id);

  -- Instant price impact, same three constraints as buy_player, in the
  -- opposite direction.
  select greatest(500, coalesce(sum(h.shares * v_price), 0))
    into v_impact_market_cap
    from public.holdings h where h.player_id = p_player_id;
  -- Same cap-then-damp order as buy_player -- see that block's comment.
  v_impact_pct := least(2.0, (v_gross / v_impact_market_cap) * 40) * v_impact_dampener;
  if v_impact_pct > 0 then
    v_impact_new_price := greatest(10, round(v_price * (1 - v_impact_pct / 100), 2));
    perform set_config(
      'scouta.price_change_reason',
      format('Sell pressure: %s SC traded (-%s%%)', round(v_gross, 2), round(v_impact_pct, 2)),
      true
    );
    update public.players set current_price = v_impact_new_price where id = p_player_id;
  end if;

  return jsonb_build_object('ok', true, 'net_proceeds', v_net, 'realized_pl', v_realized_pl, 'fee', v_fee);
end;
$function$;
