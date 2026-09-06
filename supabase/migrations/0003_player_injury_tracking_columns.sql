-- Two columns the FPL sync needs that don't exist yet:
-- - chance_of_playing_next_round: FPL's own 0/25/50/75/100/null doubt
--   signal, persisted so the sync can detect *changes* in injury doubt
--   (not just the raw number) between runs.
-- - injury_note: FPL's free-text "news" field (e.g. "Hamstring injury -
--   expected back 12 Oct"), surfaced for player pages / future
--   injury notifications rather than only affecting price silently.

alter table public.players add column if not exists chance_of_playing_next_round integer;
alter table public.players add column if not exists injury_note text;
