-- Powers "X investors hold this player" on the buy sheet. holdings has
-- owner-scoped RLS (a user can only read their own row), so a plain
-- client-side count against it would only ever see 0 or 1 for anyone
-- who isn't the current user -- this needs a SECURITY DEFINER RPC, same
-- shape as get_leaderboard, that returns only a safe aggregate (a
-- count) and never the underlying rows or who's in them.
--
-- One row per (user_id, player_id) is enforced by holdings' own unique
-- constraint, so a plain row count is already a distinct-investor count
-- -- no need for count(distinct user_id).
create or replace function public.player_investor_count(p_player_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'public'
as $$
  select count(*)::integer from public.holdings where player_id = p_player_id;
$$;

revoke all on function public.player_investor_count(uuid) from public, anon;
grant execute on function public.player_investor_count(uuid) to authenticated;
