-- RPC used by the sync-fpl-prices Edge Function to atomically update a
-- player's mirrored stats and (optionally) its price + price-history
-- reason in one transaction. This is the ONLY way current_price should
-- ever be written outside of manual admin work -- players already has no
-- INSERT/UPDATE policy for anon/authenticated, so only the service role
-- (which bypasses RLS) can reach this in practice, but it's explicitly
-- revoked from anon/authenticated here too as defense in depth, since
-- unlike buy_player/sell_player this function has no auth.uid() check at
-- all -- it must never be reachable by a regular user's own login.
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
  p_new_price numeric,   -- null = leave current_price unchanged this run
  p_reason text          -- null = no price change happened
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
      current_price = coalesce(p_new_price, current_price)
  where id = p_player_id;
end;
$$;

revoke all on function public.apply_player_sync(
  uuid, integer, integer, integer, integer, numeric, numeric, numeric,
  numeric, integer, text, numeric, text
) from public, anon, authenticated;

grant execute on function public.apply_player_sync(
  uuid, integer, integer, integer, integer, numeric, numeric, numeric,
  numeric, integer, text, numeric, text
) to service_role;
