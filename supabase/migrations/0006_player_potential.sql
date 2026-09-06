-- A real per-player Potential signal, distinct from `rating` (current
-- ability/reputation) and `current_price` (market valuation) -- matching
-- the product spec's Section 9: a scouting/opportunity signal, never a
-- direct price input. Computed by the FPL sync (Phase 1: only the 652
-- linked players get a real value; others stay null, shown as "not yet
-- available" client-side rather than a faked number, matching how the
-- rest of the app already handles missing data).
--
-- v1 formula (see sync-fpl-prices/index.ts computePotential): a
-- reasoned heuristic blending age (younger = more days of career ahead)
-- with underlying attacking output per 90 minutes (catches quality not
-- yet reflected in reputation) for players with meaningful minutes, and
-- age + rating for everyone else. Not an empirically-validated scouting
-- model -- expect to revisit.

alter table public.players add column if not exists potential numeric;

-- apply_player_sync's signature changes (adds p_potential), which in
-- Postgres creates a new overload rather than replacing the old one --
-- drop the old signature explicitly so there's never an ambiguous
-- duplicate, regardless of whether 0004 was already applied.
drop function if exists public.apply_player_sync(
  uuid, integer, integer, integer, integer, numeric, numeric, numeric,
  numeric, integer, text, numeric, text
);

create or replace function public.apply_player_sync(
  p_player_id uuid,
  p_minutes integer,
  p_goals integer,
  p_assists integer,
  p_total_points integer,
  p_form numeric,
  p_ict_index numeric,
  p_expected_goal_involvements numeric,
  p_fpl_price numeric,
  p_chance_of_playing_next_round integer,
  p_injury_note text,
  p_new_price numeric,
  p_reason text,
  p_potential numeric
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if p_reason is not null then
    perform set_config('scouta.price_change_reason', p_reason, true);
  end if;

  update public.players
  set minutes = p_minutes,
      goals = p_goals,
      assists = p_assists,
      total_points = p_total_points,
      form = p_form,
      ict_index = p_ict_index,
      expected_goal_involvements = p_expected_goal_involvements,
      fpl_price = p_fpl_price,
      chance_of_playing_next_round = p_chance_of_playing_next_round,
      injury_note = p_injury_note,
      last_synced_at = now(),
      current_price = coalesce(p_new_price, current_price),
      potential = coalesce(p_potential, potential)
  where id = p_player_id;
end;
$$;

revoke all on function public.apply_player_sync(
  uuid, integer, integer, integer, integer, numeric, numeric, numeric,
  numeric, integer, text, numeric, text, numeric
) from public, anon, authenticated;

grant execute on function public.apply_player_sync(
  uuid, integer, integer, integer, integer, numeric, numeric, numeric,
  numeric, integer, text, numeric, text, numeric
) to service_role;
