-- Scouta: close the client-writable cash_sc hole, fix a buy/sell race, and
-- defensively add two unique constraints the reward/holdings logic already
-- assumes exist.
--
-- Context: profiles.cash_sc had no lockdown trigger (unlike holdings, which
-- already has lock_down_holdings_updates), so any authenticated user could
-- PATCH /rest/v1/profiles?id=eq.<own id> with an arbitrary cash_sc value.
-- buy_player also read the existing holdings row without locking it (unlike
-- sell_player, which does), which under a concurrent buy+full-sell of the
-- same player could deduct cash for a purchase whose share increase was
-- silently lost.
--
-- Safe to run against the live project: every function below is
-- CREATE OR REPLACE with the same name/signature (existing grants and
-- PostgREST routes are untouched), and the two new unique indexes use
-- IF NOT EXISTS. If either CREATE UNIQUE INDEX fails, it means duplicate
-- rows already exist for that key -- stop and report the exact error
-- rather than re-running, since those rows need to be reconciled first.

-- ---------------------------------------------------------------------
-- 1. Lock down profiles the same way holdings is already locked down.
--    Only cash_sc / id / email are protected; scout_name, mode, and
--    onboarding_complete stay freely client-editable (the app already
--    PATCHes those directly during onboarding).
-- ---------------------------------------------------------------------
create or replace function public.lock_down_profile_updates()
returns trigger
language plpgsql
as $$
begin
  if current_setting('scouta.trusted_profile_update', true) = 'true' then
    return new;
  end if;

  if new.cash_sc is distinct from old.cash_sc
     or new.id is distinct from old.id
     or new.email is distinct from old.email then
    raise exception 'cash_sc, id, and email are managed by the server, not directly editable.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_profiles_update_lockdown on public.profiles;
create trigger enforce_profiles_update_lockdown
before update on public.profiles
for each row execute function public.lock_down_profile_updates();

-- ---------------------------------------------------------------------
-- 2. Every function that legitimately changes cash_sc now marks its
--    transaction as trusted before doing so, so the trigger above lets
--    it through. buy_player also gains "for update" on its holdings
--    read, closing the race with a concurrent full sell of the same
--    player (mirrors what sell_player already does).
-- ---------------------------------------------------------------------
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

  return jsonb_build_object('ok', true, 'net_proceeds', v_net, 'realized_pl', v_realized_pl, 'fee', v_fee);
end;
$function$;

CREATE OR REPLACE FUNCTION public.check_milestones(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cash numeric;
  v_holdings_value numeric;
  v_portfolio_value numeric;
  v_total_gain_pct numeric;
  v_profitable_sales integer;
  v_best_single_pl_pct numeric;
  v_best_single_pl numeric;
  v_reward numeric;
begin
  perform set_config('scouta.trusted_profile_update', 'true', true);

  select cash_sc into v_cash from public.profiles where id = p_user_id;

  select coalesce(sum(h.shares * pl.current_price), 0)
    into v_holdings_value
    from public.holdings h join public.players pl on pl.id = h.player_id
    where h.user_id = p_user_id;

  v_portfolio_value := v_holdings_value + v_cash;
  v_total_gain_pct := ((v_portfolio_value - 1000) / 1000) * 100;

  select count(*) into v_profitable_sales
    from public.transactions
    where user_id = p_user_id and type = 'sell' and profit > 0;

  select max(((h.shares * pl.current_price - h.shares * h.avg_buy_price) / nullif(h.shares * h.avg_buy_price, 0)) * 100),
         max(h.shares * pl.current_price - h.shares * h.avg_buy_price)
    into v_best_single_pl_pct, v_best_single_pl
    from public.holdings h join public.players pl on pl.id = h.player_id
    where h.user_id = p_user_id;

  if v_portfolio_value >= 1000 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, 'first_1000') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 25 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 25, 'First 1,000 SC portfolio');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 25 SC — First 1,000 SC portfolio');
    end if;
  end if;

  if v_total_gain_pct >= 100 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, 'return_100pct') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 50 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 50, '+100% portfolio return');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 50 SC — +100% portfolio return');
    end if;
  end if;

  if v_profitable_sales >= 10 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, 'ten_profitable') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 40 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 40, '10 profitable discoveries');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 40 SC — 10 profitable discoveries');
    end if;
  end if;

  if v_best_single_pl_pct >= 900 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, 'first_10x') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 60 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 60, 'First 10x player');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 60 SC — First 10x player');
    end if;
  end if;

  if v_best_single_pl >= 500 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, '500_profit') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 50 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 50, '500 SC single-player profit');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 50 SC — 500 SC single-player profit');
    end if;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.claim_recovery()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_cash numeric;
  v_holdings_value numeric;
  v_portfolio_value numeric;
begin
  perform set_config('scouta.trusted_profile_update', 'true', true);

  if v_user_id is null then
    return jsonb_build_object('ok', false, 'reason', 'Not authenticated.');
  end if;

  select cash_sc into v_cash from public.profiles where id = v_user_id;
  select coalesce(sum(h.shares * pl.current_price), 0) into v_holdings_value
    from public.holdings h join public.players pl on pl.id = h.player_id where h.user_id = v_user_id;
  v_portfolio_value := v_cash + v_holdings_value;

  if v_portfolio_value >= 50 then
    return jsonb_build_object('ok', false, 'reason', 'Portfolio is above the recovery floor.');
  end if;

  insert into public.claimed_milestones (user_id, milestone_key) values (v_user_id, 'recovery_topup') on conflict do nothing;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'Recovery has already been used on this account.');
  end if;

  update public.profiles set cash_sc = cash_sc + 100 where id = v_user_id;
  insert into public.transactions (user_id, type, amount, reason) values (v_user_id, 'reward', 100, 'Recovery top-up');
  insert into public.activity_log (user_id, type, detail) values (v_user_id, 'reward', 'Earned 100 SC — Recovery top-up');

  return jsonb_build_object('ok', true, 'amount', 100);
end;
$function$;

-- ---------------------------------------------------------------------
-- 3. Defensive uniqueness the reward/holdings logic already assumes.
--    If either of these fails, duplicate rows already exist for that
--    key and need to be reconciled before re-running -- report the
--    exact error rather than retrying.
-- ---------------------------------------------------------------------
create unique index if not exists claimed_milestones_user_milestone_key
  on public.claimed_milestones (user_id, milestone_key);

create unique index if not exists holdings_user_player_key
  on public.holdings (user_id, player_id);
