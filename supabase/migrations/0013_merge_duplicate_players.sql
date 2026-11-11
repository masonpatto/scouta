-- One-time cleanup: the Sportmonks sync (migration 0010) matches existing
-- rows only via ON CONFLICT (api_player_id). The original seed dataset
-- (~1,400 players spanning multiple English divisions, not just the
-- Premier League -- confirmed via a live diagnostic query, which showed
-- Championship/League One clubs like Stoke, Wrexham, Hull City duplicated
-- too) never had api_player_id populated, so every one of those players
-- got reinserted as a brand-new row the first time the Sportmonks sync
-- covered their league -- two rows per real player: an "old" row (has
-- real price history and possibly real holdings/transactions/watchlist)
-- and a "new" Sportmonks row (freshly seeded, current_price frozen at its
-- seed value).
--
-- Diagnosed via a read-only query before writing this: 1,400 old rows,
-- 2,823 new rows, 1,062 name-matched pairs, of which only 2 old rows and
-- 6 new rows are involved in an ambiguous (more-than-one-match) name
-- collision. This migration only auto-merges the UNAMBIGUOUS 1:1 pairs --
-- the handful of ambiguous names are left untouched for manual review
-- rather than risk silently merging two different real players who
-- happen to share a name.
--
-- The old row is always kept as canonical (its id, current_price,
-- price_history, and any real holdings/transactions/watchlist entries are
-- preserved) and enriched with the Sportmonks row's metadata. The new
-- row's dependents are merged in (holdings/watchlist deduped rather than
-- blindly repointed, in case a user already holds or watches both
-- duplicate rows) and the new row is then deleted. Once merged, the
-- canonical row carries the real api_player_id, so every future
-- Sportmonks sync updates it in place via its own
-- ON CONFLICT (api_player_id) -- this cannot recur for these players.

do $$
declare
  pair record;
  merged_count integer := 0;
begin
  create temporary table dup_pairs (old_id uuid, new_id uuid) on commit drop;

  insert into dup_pairs (old_id, new_id)
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
      and old.active = true
      and new.active = true
  ) p
  where p.old_match_count = 1 and p.new_match_count = 1;

  for pair in select * from dup_pairs loop
    -- 1. Holdings: if the same user holds both duplicate rows, combine
    --    into the old row (weighted-average cost basis) instead of
    --    letting a direct repoint collide with holdings_user_player_key.
    update public.holdings h_old
    set shares = h_old.shares + h_new.shares,
        avg_buy_price = case when (h_old.shares + h_new.shares) = 0 then h_old.avg_buy_price
          else (h_old.shares * h_old.avg_buy_price + h_new.shares * h_new.avg_buy_price)
               / (h_old.shares + h_new.shares) end,
        updated_at = now()
    from public.holdings h_new
    where h_old.player_id = pair.old_id
      and h_new.player_id = pair.new_id
      and h_old.user_id = h_new.user_id;

    delete from public.holdings h_new
    using public.holdings h_old
    where h_new.player_id = pair.new_id
      and h_old.player_id = pair.old_id
      and h_old.user_id = h_new.user_id;

    update public.holdings set player_id = pair.old_id where player_id = pair.new_id;

    -- 2. Watchlist: same dedupe pattern (existence-only, nothing to merge).
    delete from public.watchlist w_new
    using public.watchlist w_old
    where w_new.player_id = pair.new_id
      and w_old.player_id = pair.old_id
      and w_old.user_id = w_new.user_id;

    update public.watchlist set player_id = pair.old_id where player_id = pair.new_id;

    -- 3. No uniqueness constraint on these -- repoint directly. Done
    --    before the delete below so notifications.player_id (which has
    --    ON DELETE SET NULL) doesn't get nulled out instead of repointed.
    update public.transactions set player_id = pair.old_id where player_id = pair.new_id;
    update public.notifications set player_id = pair.old_id where player_id = pair.new_id;
    update public.activity_log set player_id = pair.old_id where player_id = pair.new_id;

    -- 4. The duplicate's price_history is just an artifact of its brief,
    --    accidental existence (seeded once, never traded) -- drop it
    --    rather than splicing an unrelated price series into the
    --    canonical row's real history.
    delete from public.price_history where player_id = pair.new_id;

    -- 5. Enrich the canonical row with Sportmonks metadata, coalescing so
    --    a field Sportmonks hasn't populated yet (e.g. rating can be null
    --    for a player not yet reached by the sync) never regresses a
    --    value the old row already had.
    update public.players old
    set api_player_id = new.api_player_id,
        name = new.name,
        full_name = coalesce(new.full_name, old.full_name),
        age = coalesce(new.age, old.age),
        date_of_birth = coalesce(new.date_of_birth, old.date_of_birth),
        nationality = coalesce(new.nationality, old.nationality),
        photo_url = coalesce(new.photo_url, old.photo_url),
        position = coalesce(new.position, old.position),
        club = coalesce(new.club, old.club),
        league = coalesce(new.league, old.league),
        rating = coalesce(new.rating, old.rating),
        active = true,
        last_synced_at = now()
    from public.players new
    where old.id = pair.old_id and new.id = pair.new_id;

    -- 6. Fully absorbed -- delete the duplicate.
    delete from public.players where id = pair.new_id;

    merged_count := merged_count + 1;
  end loop;

  raise notice 'Merged % duplicate player pairs.', merged_count;
end $$;
