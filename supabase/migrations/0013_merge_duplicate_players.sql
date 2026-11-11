-- Superseded approach: rather than merging legacy data onto the kept
-- row, just delete everything from the pre-Sportmonks seed dataset
-- outright and keep only current Sportmonks-sourced players
-- (api_player_id is not null). The legacy rows (~1,400 players across
-- multiple English divisions, seeded before Phase 2) are what caused the
-- duplicates in the first place (two rows per real player: a legacy row
-- with no api_player_id, and a Sportmonks row inserted alongside it since
-- the Sportmonks upsert only matches via ON CONFLICT (api_player_id)).
--
-- Real user data (holdings/watchlist/transactions/notifications/
-- activity_log) tied to a legacy row is repointed onto that player's
-- current Sportmonks row first, wherever an unambiguous name match
-- exists, so nothing a real account has already done (e.g. a live Buy)
-- gets silently destroyed. A legacy row with no Sportmonks match at all
-- (or an ambiguous name collision) has no current equivalent to repoint
-- to, so it -- and anything still referencing it -- is deleted outright.

do $$
declare
  pair record;
  repointed integer := 0;
  deleted_unmatched integer := 0;
begin
  create temporary table repoint_pairs (old_id uuid, new_id uuid) on commit drop;

  insert into repoint_pairs (old_id, new_id)
  select p.old_id, p.new_id
  from (
    select
      old.id as old_id,
      new.id as new_id,
      count(*) over (partition by old.id) as old_match_count,
      count(*) over (partition by new.id) as new_match_count
    from public.players old
    join public.players new
      on lower(trim(old.name)) = lower(trim(new.name))
      and old.id <> new.id
    where old.api_player_id is null
      and new.api_player_id is not null
  ) p
  where p.old_match_count = 1 and p.new_match_count = 1;

  -- 1. Repoint real user data for unambiguous matches onto the current
  --    Sportmonks row, then drop the legacy row entirely.
  for pair in select * from repoint_pairs loop
    update public.holdings h_new
    set shares = h_new.shares + h_old.shares,
        avg_buy_price = case when (h_new.shares + h_old.shares) = 0 then h_new.avg_buy_price
          else (h_new.shares * h_new.avg_buy_price + h_old.shares * h_old.avg_buy_price)
               / (h_new.shares + h_old.shares) end,
        updated_at = now()
    from public.holdings h_old
    where h_new.player_id = pair.new_id
      and h_old.player_id = pair.old_id
      and h_new.user_id = h_old.user_id;

    delete from public.holdings h_old
    using public.holdings h_new
    where h_old.player_id = pair.old_id
      and h_new.player_id = pair.new_id
      and h_old.user_id = h_new.user_id;

    update public.holdings set player_id = pair.new_id where player_id = pair.old_id;

    delete from public.watchlist w_old
    using public.watchlist w_new
    where w_old.player_id = pair.old_id
      and w_new.player_id = pair.new_id
      and w_old.user_id = w_new.user_id;

    update public.watchlist set player_id = pair.new_id where player_id = pair.old_id;

    update public.transactions set player_id = pair.new_id where player_id = pair.old_id;
    update public.notifications set player_id = pair.new_id where player_id = pair.old_id;
    update public.activity_log set player_id = pair.new_id where player_id = pair.old_id;

    -- The legacy row's own price/form history is exactly the "past"
    -- being discarded here -- the Sportmonks row's own trajectory going
    -- forward is what matters now, not a spliced-together series.
    delete from public.price_history where player_id = pair.old_id;
    delete from public.player_form_scores where player_id = pair.old_id;

    delete from public.players where id = pair.old_id;

    repointed := repointed + 1;
  end loop;

  -- 2. Everything else that's still legacy (no Sportmonks row at all, or
  --    an ambiguous name collision with no single safe match) has no
  --    current equivalent to repoint to -- delete it and anything still
  --    referencing it.
  create temporary table leftover_old_ids (id uuid) on commit drop;
  insert into leftover_old_ids select id from public.players where api_player_id is null;

  delete from public.holdings where player_id in (select id from leftover_old_ids);
  delete from public.watchlist where player_id in (select id from leftover_old_ids);
  delete from public.transactions where player_id in (select id from leftover_old_ids);
  update public.notifications set player_id = null where player_id in (select id from leftover_old_ids);
  delete from public.activity_log where player_id in (select id from leftover_old_ids);
  delete from public.price_history where player_id in (select id from leftover_old_ids);
  delete from public.player_form_scores where player_id in (select id from leftover_old_ids);

  select count(*) into deleted_unmatched from leftover_old_ids;
  delete from public.players where id in (select id from leftover_old_ids);

  raise notice 'Repointed % matched legacy players onto their Sportmonks row; deleted % unmatched legacy players outright.', repointed, deleted_unmatched;
end $$;
