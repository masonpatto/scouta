-- Phase 2, take two: API-Football is being dropped in favour of a paid
-- Sportmonks subscription (5-league plan). This migration prepares the
-- schema for the new sync-sportmonks-players Edge Function, reusing the
-- existing api_player_id/league columns rather than adding
-- Sportmonks-specific ones -- they were already generic ("external API
-- player id"), never actually populated since the API-Football function
-- was never deployed.
--
-- 1. api_player_id had NO unique constraint despite the old
--    sync-api-football-players function upserting on it with
--    onConflict: "api_player_id" -- that would have failed at runtime the
--    moment it ran (Postgres requires a matching unique/exclusion
--    constraint for ON CONFLICT), which is itself evidence that function
--    was never actually exercised against the real database.
--
-- 2. upsert_sportmonks_player: a dedicated RPC (same pattern as
--    apply_player_sync) rather than a plain client-side upsert, because
--    the write has a nuance a generic upsert can't express: current_price
--    is seeded from rating ONLY on first insert, and is never touched on
--    later refreshes (matching the FPL sync's philosophy that a price
--    only moves for a reason, never silently alongside an unrelated
--    stats refresh).

create unique index if not exists players_api_player_id_key
  on public.players (api_player_id)
  where api_player_id is not null;

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
begin
  insert into public.players (
    api_player_id, name, full_name, age, date_of_birth, nationality,
    photo_url, position, club, league, rating, current_price, active,
    last_synced_at
  )
  values (
    p_api_player_id, p_name, p_full_name, p_age, p_date_of_birth, p_nationality,
    p_photo_url, p_position, p_club, p_league, p_rating,
    coalesce(p_seed_price, 10), true, now()
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
    active = true,
    last_synced_at = now();
    -- current_price deliberately absent: never overwritten after the
    -- first insert seeds it.
end;
$$;

revoke all on function public.upsert_sportmonks_player(
  integer, text, text, integer, date, text, text, text, text, text, integer, numeric
) from public, anon, authenticated;

grant execute on function public.upsert_sportmonks_player(
  integer, text, text, integer, date, text, text, text, text, text, integer, numeric
) to service_role;
