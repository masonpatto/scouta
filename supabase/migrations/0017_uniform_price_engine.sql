-- A uniform price engine covering every player in every subscribed
-- league, replacing the Premier-League-only FPL price sync (which was
-- never actually connected -- fpl_id was never populated on any
-- player -- and has now been deleted along with apply_player_sync).
--
-- Rather than a second, separate data pipeline with narrower coverage,
-- this builds directly on sync-sportmonks-players, which already
-- visits every active player across all 5 leagues and already computes
-- a fresh `rating` from real match evidence (per-match performance,
-- shrunk by playing time) on every pass. That rating IS the evidence
-- signal -- this migration just makes price track it, instead of
-- rating being computed and current_price sitting frozen forever.
--
-- Mechanics: price_basis_rating stores the rating current_price was
-- last computed from. Every sync, upsert_sportmonks_player compares
-- the incoming rating against that baseline. Any real change (rating
-- is already an integer, so any difference is a genuine move, not
-- rounding noise) nudges price by MOVE_PCT_PER_POINT per rating point,
-- hard-capped at +/-HARD_CAP_PCT per sync pass -- same shape as the
-- old FPL engine's design, just driven by a signal that already covers
-- every league instead of one.
--
-- Honest limitation, not hidden: CURATED_RATINGS (the ~2,044 real EA
-- FC 27 ratings for recognizable players) are a dated snapshot, not a
-- continuously recomputed signal -- those players' price only moves
-- again when that dataset is next refreshed, same as their rating.
-- Every other player (the long tail nobody's curated by name) moves
-- automatically, every sync pass, purely from on-pitch evidence.
--
-- Safe to run more than once: CREATE OR REPLACE throughout, column add
-- is IF NOT EXISTS, trigger is DROP + CREATE.

alter table public.players add column if not exists price_basis_rating numeric;

-- Backfill: start every existing player's baseline at their current
-- rating, so the next sync compares against today, not against null
-- (which would otherwise read as a huge false first-ever delta and
-- move everyone's price at once).
update public.players
set price_basis_rating = rating
where price_basis_rating is null and rating is not null;

-- Recreated defensively (idempotent either way) since this is the
-- trigger that actually writes every price change to price_history.
create or replace function public.log_price_change()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.current_price is distinct from old.current_price then
    insert into public.price_history (player_id, price, recorded_at, reason)
    values (new.id, new.current_price, now(), current_setting('scouta.price_change_reason', true));
    perform set_config('scouta.price_change_reason', null, true);
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_log_price_change on public.players;
create trigger trg_log_price_change
  after update on public.players
  for each row execute function public.log_price_change();

create or replace function public.upsert_sportmonks_player(
  p_api_player_id integer,
  p_name text,
  p_full_name text,
  p_age integer,
  p_date_of_birth date,
  p_nationality text,
  p_photo_url text,
  p_position text,
  p_club text,
  p_league text,
  p_rating integer,
  p_seed_price numeric
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_basis numeric;
  v_price numeric;
  v_delta numeric;
  v_move_pct numeric;
  v_new_price numeric;
  v_move_pct_per_point constant numeric := 3.0;
  v_hard_cap_pct constant numeric := 15.0;
begin
  select price_basis_rating, current_price into v_basis, v_price
    from public.players where api_player_id = p_api_player_id;

  if v_basis is null then
    -- First time we've seen this player (new insert, or an existing
    -- row whose basis was never backfilled) -- nothing to compare
    -- against yet, so just seed the baseline, no price move.
    v_new_price := null;
  else
    v_delta := p_rating - v_basis;
    if v_delta is not null and v_delta <> 0 then
      v_move_pct := greatest(-v_hard_cap_pct, least(v_hard_cap_pct, v_delta * v_move_pct_per_point));
      v_new_price := greatest(10, round(coalesce(v_price, p_seed_price, 10) * (1 + v_move_pct / 100), 2));
      perform set_config(
        'scouta.price_change_reason',
        format('Rating moved %s%s points (%s -> %s)', case when v_delta > 0 then '+' else '' end, v_delta, v_basis, p_rating),
        true
      );
    end if;
  end if;

  insert into public.players (
    api_player_id, name, full_name, age, date_of_birth, nationality,
    photo_url, position, club, league, rating, current_price,
    price_basis_rating, active, last_synced_at
  )
  values (
    p_api_player_id, p_name, p_full_name, p_age, p_date_of_birth, p_nationality,
    p_photo_url, p_position, p_club, p_league, p_rating,
    coalesce(p_seed_price, 10), p_rating, true, now()
  )
  on conflict (api_player_id) do update set
    name = excluded.name,
    full_name = excluded.full_name,
    age = excluded.age,
    date_of_birth = excluded.date_of_birth,
    nationality = excluded.nationality,
    photo_url = excluded.photo_url,
    position = excluded.position,
    club = excluded.club,
    league = excluded.league,
    rating = excluded.rating,
    current_price = coalesce(v_new_price, public.players.current_price),
    -- New baseline is the rating that justified the move (or, if this
    -- row somehow never got one, today's rating as a fresh starting
    -- point) -- otherwise unchanged, since nothing moved.
    price_basis_rating = case
      when v_new_price is not null then p_rating
      when v_basis is null then p_rating
      else public.players.price_basis_rating
    end,
    active = true,
    last_synced_at = now();
end;
$$;

revoke all on function public.upsert_sportmonks_player(
  integer, text, text, integer, date, text, text, text, text, text, integer, numeric
) from public, anon, authenticated;

grant execute on function public.upsert_sportmonks_player(
  integer, text, text, integer, date, text, text, text, text, text, integer, numeric
) to service_role;
