-- Two gaps found in the audit:
--
-- 1. The leaderboard is currently broken, not just "ranked by the wrong
--    field": profiles' SELECT policy is `auth.uid() = id` (own row only),
--    so the client's plain `select id, scout_name, cash_sc from profiles
--    order by cash_sc desc` can only ever return the caller's own row
--    under RLS. It never showed a real cross-user leaderboard. Fixed
--    here with a SECURITY DEFINER function that returns only the fields
--    a leaderboard needs (name, portfolio value, ROI%) -- never raw
--    cash_sc or email -- ranked by ROI% per the spec ("primarily ROI%").
--
-- 2. No account deletion existed at all (App Store/Play Store
--    requirement, and in the user's explicit launch checklist).

create or replace function public.get_leaderboard(p_limit integer default 20)
returns table (
  user_id uuid,
  scout_name text,
  portfolio_value numeric,
  roi_pct numeric
)
language sql
security definer
stable
set search_path to 'public'
as $$
  select
    p.id as user_id,
    coalesce(p.scout_name, 'Scout') as scout_name,
    (p.cash_sc + coalesce(h.holdings_value, 0)) as portfolio_value,
    round(((p.cash_sc + coalesce(h.holdings_value, 0) - 1000) / 1000) * 100, 1) as roi_pct
  from public.profiles p
  left join (
    select ho.user_id, sum(ho.shares * pl.current_price) as holdings_value
    from public.holdings ho
    join public.players pl on pl.id = ho.player_id
    group by ho.user_id
  ) h on h.user_id = p.id
  where p.onboarding_complete = true
  order by roi_pct desc
  limit p_limit;
$$;

revoke all on function public.get_leaderboard(integer) from public;
grant execute on function public.get_leaderboard(integer) to authenticated;

-- Deletes everything belonging to the caller's own account, then the
-- auth.users row itself (Supabase's own session/identity tables cascade
-- from that). Order matters only in that it's safe regardless of
-- whatever FK cascade behavior is actually configured: children go
-- first, so nothing depends on cascades existing at all.
create or replace function public.delete_own_account()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'reason', 'Not authenticated.');
  end if;

  delete from public.watchlist where user_id = v_user_id;
  delete from public.claimed_milestones where user_id = v_user_id;
  delete from public.activity_log where user_id = v_user_id;
  delete from public.transactions where user_id = v_user_id;
  delete from public.holdings where user_id = v_user_id;
  delete from public.profiles where id = v_user_id;
  delete from auth.users where id = v_user_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
