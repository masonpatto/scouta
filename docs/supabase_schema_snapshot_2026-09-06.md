# Supabase schema snapshot — 2026-09-06

Captured from the live project via SQL Editor queries (function bodies, RLS
policies, RLS-enabled flags, table columns, and the `public`/`auth` triggers)
as part of the pre-launch security/reliability audit. This is a point-in-time
reference, not a replayable migration — see
`supabase/migrations/0001_fix_profile_lockdown_and_buy_race.sql` for the
actual fix applied on top of this state.

Audit findings from this snapshot:

- **Critical (fixed in migration 0001):** `profiles` had no lockdown trigger
  on `UPDATE`, unlike `holdings` (which already has
  `lock_down_holdings_updates`). Any authenticated user could
  `PATCH /rest/v1/profiles?id=eq.<own id>` with an arbitrary `cash_sc` and
  it would succeed — RLS only checked row ownership, not which columns or
  values were being changed.
- **High (fixed in migration 0001):** `buy_player` read the existing
  `holdings` row without `for update` (unlike `sell_player`, which does
  lock it). Under a concurrent buy + full-sell of the same player, the
  buy's `UPDATE` could silently match zero rows after the sell deleted the
  row, deducting cash for a purchase that never actually landed.
- **Needs verification (defensively fixed in migration 0001):** no
  confirmed unique constraint on `claimed_milestones (user_id,
  milestone_key)` or `holdings (user_id, player_id)` — both are load-bearing
  assumptions of `check_milestones`'s `ON CONFLICT DO NOTHING` idempotency
  and of `buy_player`'s single-row-per-position logic.
- **Confirmed solid:** `buy_player`/`sell_player` correctly enforce the 5 SC
  minimum, 2% fee, weighted-average cost basis, and a genuinely-correct
  (verified algebraically) 30% post-trade concentration cap. `players` has
  no INSERT/UPDATE policy for regular users at all, so price manipulation
  via client trading is structurally impossible. `handle_new_user` +
  `ensure_profile_exists` correctly prevent duplicate starting balances.
- **Open design question:** `sell_player` grants an automatic reward (5% of
  profit, capped at 30 SC) on *every* profitable sale with no frequency
  limit — worth revisiting against "rewards should be small, infrequent,
  and outcome-based."
- **Schema suggests real football-data integration was planned/started**:
  `players` has `fpl_id`, `fpl_price`, `fd_player_id`, `last_synced_at`
  columns, and a `sync_state` table exists — but no ingestion job/Edge
  Function is present in this git repo. Status unconfirmed as of this
  snapshot.

## Raw export

```
===== FUNCTIONS =====

-- FUNCTION: buy_player
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
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'reason', 'Not authenticated.');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'Enter an amount to invest.');
  end if;

  if p_amount < 5 then
    return jsonb_build_object('ok', false, 'reason', 'Minimum investment is 5 SC.');
  end if;

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

  select shares, avg_buy_price into v_existing_shares, v_existing_avg_buy
    from public.holdings where user_id = v_user_id and player_id = p_player_id;

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
$function$


-- FUNCTION: check_milestones
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
$function$


-- FUNCTION: claim_recovery
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
$function$


-- FUNCTION: ensure_profile_exists
CREATE OR REPLACE FUNCTION public.ensure_profile_exists()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_email text;
begin
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'reason', 'Not authenticated.');
  end if;

  if exists (select 1 from public.profiles where id = v_user_id) then
    return jsonb_build_object('ok', true, 'created', false);
  end if;

  select email into v_email from auth.users where id = v_user_id;

  insert into public.profiles (id, email, cash_sc)
  values (v_user_id, v_email, 1000.00);

  return jsonb_build_object('ok', true, 'created', true);
end;
$function$


-- FUNCTION: handle_new_user
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.profiles (id, email, cash_sc)
  values (new.id, new.email, 1000.00);
  return new;
end;
$function$


-- FUNCTION: lock_down_holdings_updates
CREATE OR REPLACE FUNCTION public.lock_down_holdings_updates()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if current_setting('scouta.trusted_holdings_update', true) = 'true' then
    return new;
  end if;

  if new.shares is distinct from old.shares
     or new.avg_buy_price is distinct from old.avg_buy_price
     or new.player_id is distinct from old.player_id
     or new.user_id is distinct from old.user_id then
    raise exception 'Only thesis can be updated directly. shares, avg_buy_price, player_id, and user_id are managed by buy_player/sell_player.';
  end if;
  return new;
end;
$function$


-- FUNCTION: log_price_change
CREATE OR REPLACE FUNCTION public.log_price_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.current_price is distinct from old.current_price then
    insert into public.price_history (player_id, price, recorded_at)
    values (new.id, new.current_price, now());
  end if;
  return new;
end;
$function$


-- FUNCTION: name_tokens
CREATE OR REPLACE FUNCTION public.name_tokens(n text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select array_remove(
    string_to_array(
      regexp_replace(lower(unaccent(coalesce(n, ''))), '[^a-z0-9 -]', '', 'g'),
      ' '
    ),
    ''
  );
$function$


-- FUNCTION: player_age
CREATE OR REPLACE FUNCTION public.player_age(dob date)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when dob is null then null
    else extract(year from age(dob))::integer end;
$function$


-- FUNCTION: price_change_pct
CREATE OR REPLACE FUNCTION public.price_change_pct(p_player_id uuid, p_hours integer)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  select case
    when earliest.price is null or earliest.price = 0 then null
    else round(((current.price - earliest.price) / earliest.price) * 100, 2)
  end
  from
    (select current_price as price from public.players where id = p_player_id) as current,
    (
      select price from public.price_history
      where player_id = p_player_id
        and recorded_at <= now() - (p_hours || ' hours')::interval
      order by recorded_at desc
      limit 1
    ) as earliest;
$function$


-- FUNCTION: sell_player
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
$function$


-- FUNCTION: unaccent / unaccent_init / unaccent_lexize
-- (postgres 'unaccent' extension built-ins, unmodified)


===== RLS POLICIES =====

TABLE: activity_log | POLICY: Users can log their own watchlist activity | CMD: INSERT | ROLES: {public}
  USING: (none)
  WITH CHECK: ((auth.uid() = user_id) AND (type = ANY (ARRAY['watchlist_add'::text, 'watchlist_remove'::text])))
---
TABLE: activity_log | POLICY: Users can view their own activity | CMD: SELECT | ROLES: {public}
  USING: (auth.uid() = user_id)
---
TABLE: claimed_milestones | POLICY: Users can view their own claimed milestones | CMD: SELECT | ROLES: {public}
  USING: (auth.uid() = user_id)
---
TABLE: holdings | POLICY: Users can update their own holding's thesis | CMD: UPDATE | ROLES: {public}
  USING: (auth.uid() = user_id)
  WITH CHECK: (auth.uid() = user_id)
---
TABLE: holdings | POLICY: Users can view their own holdings | CMD: SELECT | ROLES: {public}
  USING: (auth.uid() = user_id)
---
TABLE: players | POLICY: Any authenticated user can view players | CMD: SELECT | ROLES: {public}
  USING: (auth.role() = 'authenticated'::text)
---
TABLE: price_history | POLICY: Anyone can view price history | CMD: SELECT | ROLES: {public}
  USING: true
---
TABLE: profiles | POLICY: Users can update their own profile | CMD: UPDATE | ROLES: {public}
  USING: (auth.uid() = id)
  WITH CHECK: (none)          <-- no column restriction; see critical finding above
---
TABLE: profiles | POLICY: Users can view their own profile | CMD: SELECT | ROLES: {public}
  USING: (auth.uid() = id)
---
TABLE: transactions | POLICY: Users can view their own transactions | CMD: SELECT | ROLES: {public}
  USING: (auth.uid() = user_id)
---
TABLE: watchlist | POLICY: Users can add to their own watchlist | CMD: INSERT | ROLES: {public}
  WITH CHECK: (auth.uid() = user_id)
---
TABLE: watchlist | POLICY: Users can remove from their own watchlist | CMD: DELETE | ROLES: {public}
  USING: (auth.uid() = user_id)
---
TABLE: watchlist | POLICY: Users can view their own watchlist | CMD: SELECT | ROLES: {public}
  USING: (auth.uid() = user_id)


===== RLS ENABLED STATUS =====

activity_log: RLS=true FORCED=false
claimed_milestones: RLS=true FORCED=false
holdings: RLS=true FORCED=false
players: RLS=true FORCED=false
price_history: RLS=true FORCED=false
profiles: RLS=true FORCED=false
sync_state: RLS=true FORCED=false
transactions: RLS=true FORCED=false
watchlist: RLS=true FORCED=false


===== TABLE COLUMNS =====

activity_log.id uuid NOT NULL DEFAULT gen_random_uuid()
activity_log.user_id uuid NOT NULL
activity_log.type text NOT NULL
activity_log.player_id uuid
activity_log.detail text NOT NULL
activity_log.created_at timestamp with time zone NOT NULL DEFAULT now()
claimed_milestones.user_id uuid NOT NULL
claimed_milestones.milestone_key text NOT NULL
claimed_milestones.claimed_at timestamp with time zone NOT NULL DEFAULT now()
holdings.id uuid NOT NULL DEFAULT gen_random_uuid()
holdings.user_id uuid NOT NULL
holdings.player_id uuid NOT NULL
holdings.shares numeric NOT NULL
holdings.avg_buy_price numeric NOT NULL
holdings.created_at timestamp with time zone NOT NULL DEFAULT now()
holdings.updated_at timestamp with time zone NOT NULL DEFAULT now()
holdings.thesis text
players.id uuid NOT NULL DEFAULT gen_random_uuid()
players.name text NOT NULL
players.club text
players.position text
players.age integer
players.nationality text
players.current_price numeric NOT NULL DEFAULT 100
players.price_updated_at timestamp with time zone NOT NULL DEFAULT now()
players.created_at timestamp with time zone NOT NULL DEFAULT now()
players.rating integer
players.api_player_id integer
players.photo_url text
players.active boolean NOT NULL DEFAULT true
players.last_synced_at timestamp with time zone
players.fpl_id integer
players.minutes integer
players.goals integer
players.assists integer
players.total_points integer
players.form numeric
players.ict_index numeric
players.expected_goal_involvements numeric
players.fpl_price numeric
players.fd_player_id integer
players.date_of_birth date
players.full_name text
price_history.id uuid NOT NULL DEFAULT gen_random_uuid()
price_history.player_id uuid NOT NULL
price_history.price numeric NOT NULL
price_history.recorded_at timestamp with time zone NOT NULL DEFAULT now()
profiles.id uuid NOT NULL
profiles.email text NOT NULL
profiles.scout_name text
profiles.mode text NOT NULL DEFAULT 'casual'::text
profiles.cash_sc numeric NOT NULL DEFAULT 1000.00
profiles.onboarding_complete boolean NOT NULL DEFAULT false
profiles.created_at timestamp with time zone NOT NULL DEFAULT now()
sync_state.key text NOT NULL
sync_state.value integer NOT NULL DEFAULT 0
sync_state.updated_at timestamp with time zone NOT NULL DEFAULT now()
transactions.id uuid NOT NULL DEFAULT gen_random_uuid()
transactions.user_id uuid NOT NULL
transactions.player_id uuid
transactions.type text NOT NULL
transactions.shares numeric
transactions.price numeric
transactions.amount numeric NOT NULL
transactions.fee numeric DEFAULT 0
transactions.profit numeric
transactions.reason text
transactions.created_at timestamp with time zone NOT NULL DEFAULT now()
watchlist.id uuid NOT NULL DEFAULT gen_random_uuid()
watchlist.user_id uuid NOT NULL
watchlist.player_id uuid NOT NULL
watchlist.created_at timestamp with time zone NOT NULL DEFAULT now()


===== TRIGGERS (public schema) =====

players | on_player_price_change | AFTER UPDATE | EXECUTE FUNCTION log_price_change()
holdings | enforce_holdings_update_lockdown | BEFORE UPDATE | EXECUTE FUNCTION lock_down_holdings_updates()

===== TRIGGERS (auth schema) =====

auth.users | on_auth_user_created | AFTER INSERT | EXECUTE FUNCTION handle_new_user()
```
