-- 0010 created players_api_player_id_key as a PARTIAL unique index
-- (`where api_player_id is not null`), but a plain `on conflict
-- (api_player_id)` can only target a full unique index/constraint --
-- matching a partial one requires repeating its exact predicate in the
-- ON CONFLICT clause itself, which upsert_sportmonks_player didn't do.
-- That's why every upsert failed with "there is no unique or exclusion
-- constraint matching the ON CONFLICT specification".
--
-- The partial condition was unnecessary in the first place: a normal
-- (non-partial) unique index already allows any number of NULL rows in
-- Postgres (NULL is never considered equal to another NULL), which is
-- exactly what the ~1,400 existing players with no api_player_id need.
-- So this just replaces it with a plain unique index instead of also
-- rewriting the RPC to repeat the predicate.

drop index if exists public.players_api_player_id_key;

create unique index if not exists players_api_player_id_key
  on public.players (api_player_id);
