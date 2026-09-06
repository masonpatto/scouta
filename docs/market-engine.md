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

- **Not the other 746 non-PL players** (49 clubs total, only 20 are
  Premier League) — those need football-data.org (or another provider)
  and a paid/free-tier API key you'll need to obtain yourself. That's
  Phase 2, not built yet.
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
