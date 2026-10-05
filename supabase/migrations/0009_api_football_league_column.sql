-- Phase 2 prep: tag which competition a player belongs to. `players`
-- already has `api_player_id` (unused until now) for the external ID and
-- `club` (free text) for the team -- this just adds the missing
-- league/competition label alongside them. Nullable and additive only;
-- existing Premier League rows are backfilled for consistency.

alter table public.players add column if not exists league text;

update public.players
set league = 'Premier League'
where league is null and fpl_id is not null;
