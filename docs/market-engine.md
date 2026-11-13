# Scouta market engine — Phase 1 (Premier League via FPL)

## What this is

A daily job that updates the 652 `players` rows already linked to a
Premier League player (`fpl_id` is set) with real match data from the free
Fantasy Premier League API, and moves `current_price` only when there's
genuine evidence to react to — never from trading volume, hype, or the
`rating`/Potential field.

Price only reacts to, since the last sync:
- FPL points scored (blends goals/assists/minutes/clean sheets/bonus)
- Change in expected-goal-involvement (catches good underlying performances
  before headline stats catch up)
- New minutes played (role/rotation signal)
- A change in FPL's injury-doubt flag (`chance_of_playing_next_round`) —
  reacting to the doubt appearing/clearing, not its static value

Every move is hard-capped at ±15% (see `HARD_CAP_PCT` in the function);
in practice a normal gameweek should move most prices by low single
digits. A quiet day with no new evidence leaves the price untouched
entirely (below `MIN_MOVE_PCT`).

**The weights in `sync-fpl-prices/index.ts` are a reasoned starting
point, not empirically tuned.** Watch a few real gameweeks of
`price_history` and adjust `POINTS_WEIGHT` / `XGI_WEIGHT` /
`MINUTES_FULL_MATCH_BONUS` if moves feel too large or too flat.

Every price change is logged to `price_history` with a human-readable
`reason` (e.g. "Gameweek sync: +6 pts, xGI +0.31, +90 min").

## What this is NOT (yet)

- **Not the other non-PL players** — see Phase 2 below.
- **Not a roster-seeding job** — it never inserts new players, only
  updates the 652 already linked by `fpl_id`. Adding newly-promoted or
  newly-transferred-in players to that linked set is a separate task.
- **Not live/in-match pricing** — FPL's own totals update during live
  matches, so if the cron happens to run mid-match some players might
  reflect a partially-played gameweek. Harmless (it'll just catch the
  rest of the delta next run), but worth knowing.

## One-time setup

### 1. Run the migrations (if not already applied)

`0002_price_history_reason.sql`, `0003_player_injury_tracking_columns.sql`,
and `0004_player_sync_rpc.sql`, in that order, via the SQL Editor.

### 2. Deploy the Edge Function

In the Supabase dashboard: **Edge Functions → Create a new function**,
name it exactly `sync-fpl-prices`, paste in the contents of
`supabase/functions/sync-fpl-prices/index.ts`, and deploy. No secrets
need to be configured — `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
are injected automatically into every Edge Function.

### 3. Test it once manually before scheduling

Trigger it directly (from the Edge Functions page there's usually an
"Invoke"/test option, or call it with your project's service role key).
It should respond with something like:
```json
{"ok": true, "matched": 652, "price_changed": 480, "errors": [], "error_count": 0}
```
If `matched` is 0, the function likely isn't reaching the players table
correctly — stop and check before scheduling it to run unattended.

### 4. Store the service role key in Vault (for the cron job to use)

Run in the SQL Editor (replace `YOUR_SERVICE_ROLE_KEY` with the actual
key from **Project Settings → API**):

```sql
select vault.create_secret('YOUR_SERVICE_ROLE_KEY', 'service_role_key');
```

This keeps the key out of the cron job definition itself.

### 5. Schedule the daily run

```sql
select cron.schedule(
  'sync-fpl-prices-daily',
  '0 6 * * *', -- 6am UTC daily; adjust to taste
  $$
  select net.http_post(
    url := 'https://eqflsykuoyuzbcixayjl.supabase.co/functions/v1/sync-fpl-prices',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := '{}'::jsonb
  );
  $$
);
```

If `cron.schedule` or `net.http_post` errors saying the extension doesn't
exist, enable `pg_cron` and `pg_net` first via **Database → Extensions**,
then re-run.

### Checking it's working

```sql
select * from cron.job_run_details order by start_time desc limit 5;
```
and
```sql
select player_id, price, reason, recorded_at
from price_history
order by recorded_at desc
limit 20;
```

# Scouta market engine — Phase 2 (all other leagues via Sportmonks)

## What this is

A job that seeds and refreshes every player in every league your
Sportmonks subscription includes (not just Premier League), using the
Sportmonks Football API v3. It's fully subscription-driven: it calls
`GET /leagues` and processes whatever leagues come back, so adding a
league to your Sportmonks plan later means this job picks it up on its
next run — no code change needed.

This replaces an earlier plan to use API-Football for this; that
function (`sync-api-football-players`) was written but never actually
deployed, and has been removed from this repo.

Unlike Phase 1, this job **does** insert new players (roster seeding)
and refreshes their rating/position/club/nationality metadata on every
run. It does **not** touch `current_price` after the first time a player
is inserted — matching Phase 1's philosophy that price only moves for a
specific, loggable reason, never silently alongside a routine metadata
refresh. There is no Sportmonks-driven price-mover job (the equivalent of
Phase 1's points/xGI-based price engine) — these players' prices stay
exactly as seeded until a future job is built for that.

**The rating formula in `sync-sportmonks-players/index.ts` is an
unverified assumption, not a confirmed one.** Sportmonks' player
`rating` statistic (type_id 118) is assumed to be roughly a 0–10 scale
and multiplied by 10 the same way the old API-Football plan treated its
own 0–10 rating field. Check the first real run's output: if most
ratings are clamped at the 40 floor or 99 ceiling, that assumption is
wrong and the formula in `extractRating`/the `rating100` calculation
needs adjusting against whatever the real response shape turns out to
be.

## One-time setup

### 1. Run the migration (if not already applied)

`0010_sportmonks_player_sync.sql`, via the SQL Editor. This adds a
unique index on `players.api_player_id` (required for the upsert to work
at all — it was missing before, which is also why the old API-Football
function could never have actually run successfully) and the
`upsert_sportmonks_player` RPC the Edge Function calls.

### 2. Get a Sportmonks API token

In [MySportmonks](https://my.sportmonks.com/) → API → Tokens → Create.
Full steps: https://docs.sportmonks.com/v3/welcome/authentication

### 3. Deploy the Edge Function

In the Supabase dashboard: **Edge Functions → Create a new function**,
name it exactly `sync-sportmonks-players`, paste in the contents of
`supabase/functions/sync-sportmonks-players/index.ts`, and deploy. Then
add one secret: **Edge Functions → Secrets →** `SPORTMONKS_API_TOKEN`
(the token from step 2). `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
are injected automatically, same as Phase 1.

### 4. Test it once manually before scheduling

This job processes a bounded number of teams per call (`TEAM_BUDGET`,
15 by default) and picks up where it left off, because Supabase Edge
Functions cap a single invocation at 150s wall-clock and 2s of actual
CPU time — trying to do all ~100+ teams in one call hits that limit and
just hangs before failing. Trigger it directly (Edge Functions page →
Invoke, or call it with your project's service role key); a healthy
first response looks like:
```json
{"ok": true, "done": false, "upserted_this_run": 120, "teams_total": 106, "resumed_at_team_idx": 15, "api_calls_this_run": 20, "upsert_error_count": 0, "log": [...], "note": "Budget reached for this run -- call again (91 team(s) left) to continue."}
```
Keep invoking it until a response says `"done": true` — that's a full
pass across every team. Read the `log` array on the first call — it
names every league the function found. If it's not the 5 leagues you
subscribed to, or `upserted_this_run` stays 0, stop and check before
continuing. Once fully done, sanity-check a handful of real rows:
```sql
select name, club, league, position, rating, current_price, nationality
from players
where api_player_id is not null
order by last_synced_at desc
limit 20;
```
If `rating` looks implausible (everything at 40 or everything at 99),
see the note above about the unverified rating-scale assumption.

### 5. Store the service role key in Vault (if not already done for Phase 1)

Same step as Phase 1 — skip if `service_role_key` already exists in
Vault:
```sql
select vault.create_secret('YOUR_SERVICE_ROLE_KEY', 'service_role_key');
```

### 6. Schedule a run

**Check the function's actual URL slug before wiring up the cron.**
Supabase's dashboard shows a function by its display name, but routes
requests by a separate slug — these can silently differ (ours did:
displayed as `sync-sportmonks-players`, actually slugged `super-task`,
which made every cron/pg_net call to `.../functions/v1/sync-sportmonks-players`
404 for days while the dashboard's own "Test" button worked fine,
since Test invokes by internal ID rather than the public URL). Confirm
the real slug via the Management API (`GET /v1/projects/{ref}/functions`,
needs a personal access token) or by testing the invoke URL directly
with `curl` before scheduling anything against it — don't assume the
display name is the slug.

Because each call only processes `TEAM_BUDGET` (15) teams, a run once a
day would take roughly a week to complete one full pass across ~106
teams. Schedule it hourly instead — at 15 teams/call that's a full pass
every ~7 hours, so rosters and ratings stay reasonably fresh without
needing a bigger per-call budget:
```sql
select cron.schedule(
  'sync-sportmonks-players-hourly',
  '0 * * * *', -- hourly
  $$
  select net.http_post(
    -- "super-task" is this function's real slug, not its display name
    -- (sync-sportmonks-players) -- see the note above.
    url := 'https://eqflsykuoyuzbcixayjl.supabase.co/functions/v1/super-task',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
```
