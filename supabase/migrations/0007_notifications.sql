-- Notifications v1: in-app only (no push delivery infra exists yet --
-- that needs Expo push tokens and its own device-testing pass, tracked
-- separately). Covers the three v1 cases from the spec: price moves,
-- injury news, and milestone claims, scoped to players a user actually
-- holds or watches. Deliberately not overbuilt: no categories/settings,
-- just a flat feed.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null, -- 'price_move' | 'injury' | 'milestone'
  title text not null,
  body text not null,
  player_id uuid references public.players(id) on delete set null,
  read boolean not null default false,
  created_at timestamp with time zone not null default now()
);

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "Users can view their own notifications" on public.notifications;
create policy "Users can view their own notifications"
  on public.notifications for select
  using (auth.uid() = user_id);

-- Marking read/unread is low-stakes (no economic value in these rows),
-- so a plain owner-scoped UPDATE policy is enough -- no lockdown
-- trigger needed here, unlike holdings/profiles.
drop policy if exists "Users can update their own notifications" on public.notifications;
create policy "Users can update their own notifications"
  on public.notifications for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- Price-move + injury-news notifications: fires once per players row
-- update, for every user who holds or watches that player.
--
-- NOTE on trigger ordering: this reads scouta.price_change_reason,
-- which log_price_change() (the existing on_player_price_change
-- trigger) also reads and then clears. Postgres fires same-event
-- triggers in alphabetical order by trigger name, and
-- "notify_interested_users_trigger" < "on_player_price_change"
-- alphabetically, so this one reads the reason first, correctly. If
-- either trigger is ever renamed, re-check this ordering.
-- ---------------------------------------------------------------------
create or replace function public.notify_interested_users()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_move_pct numeric;
  v_title text;
  v_body text;
  v_type text;
begin
  if new.current_price is distinct from old.current_price and old.current_price > 0 then
    v_move_pct := round(((new.current_price - old.current_price) / old.current_price) * 100, 1);
    if abs(v_move_pct) >= 5 then
      v_type := 'price_move';
      v_title := new.name || (case when v_move_pct > 0 then ' is up ' else ' is down ' end) || abs(v_move_pct) || '%';
      v_body := coalesce(current_setting('scouta.price_change_reason', true), 'Price updated.');

      insert into public.notifications (user_id, type, title, body, player_id)
      select distinct u.user_id, v_type, v_title, v_body, new.id
      from (
        select user_id from public.holdings where player_id = new.id
        union
        select user_id from public.watchlist where player_id = new.id
      ) u;
    end if;
  end if;

  if new.injury_note is distinct from old.injury_note and new.injury_note is not null and new.injury_note <> '' then
    insert into public.notifications (user_id, type, title, body, player_id)
    select distinct u.user_id, 'injury', new.name || ': injury update', new.injury_note, new.id
    from (
      select user_id from public.holdings where player_id = new.id
      union
      select user_id from public.watchlist where player_id = new.id
    ) u;
  end if;

  return new;
end;
$$;

drop trigger if exists notify_interested_users_trigger on public.players;
create trigger notify_interested_users_trigger
after update on public.players
for each row execute function public.notify_interested_users();

-- ---------------------------------------------------------------------
-- Milestone notifications: extend check_milestones to also write a
-- notification alongside each reward it already grants.
-- ---------------------------------------------------------------------
create or replace function public.check_milestones(p_user_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
      insert into public.notifications (user_id, type, title, body) values (p_user_id, 'milestone', 'Milestone: First 1,000 SC portfolio', 'You earned 25 SC.');
    end if;
  end if;

  if v_total_gain_pct >= 100 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, 'return_100pct') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 50 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 50, '+100% portfolio return');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 50 SC — +100% portfolio return');
      insert into public.notifications (user_id, type, title, body) values (p_user_id, 'milestone', 'Milestone: +100% portfolio return', 'You earned 50 SC.');
    end if;
  end if;

  if v_profitable_sales >= 10 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, 'ten_profitable') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 40 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 40, '10 profitable discoveries');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 40 SC — 10 profitable discoveries');
      insert into public.notifications (user_id, type, title, body) values (p_user_id, 'milestone', 'Milestone: 10 profitable discoveries', 'You earned 40 SC.');
    end if;
  end if;

  if v_best_single_pl_pct >= 900 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, 'first_10x') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 60 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 60, 'First 10x player');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 60 SC — First 10x player');
      insert into public.notifications (user_id, type, title, body) values (p_user_id, 'milestone', 'Milestone: First 10x player', 'You earned 60 SC.');
    end if;
  end if;

  if v_best_single_pl >= 500 then
    insert into public.claimed_milestones (user_id, milestone_key) values (p_user_id, '500_profit') on conflict do nothing;
    if found then
      update public.profiles set cash_sc = cash_sc + 50 where id = p_user_id;
      insert into public.transactions (user_id, type, amount, reason) values (p_user_id, 'reward', 50, '500 SC single-player profit');
      insert into public.activity_log (user_id, type, detail) values (p_user_id, 'reward', 'Earned 50 SC — 500 SC single-player profit');
      insert into public.notifications (user_id, type, title, body) values (p_user_id, 'milestone', 'Milestone: +500 SC on one player', 'You earned 50 SC.');
    end if;
  end if;
end;
$function$;
