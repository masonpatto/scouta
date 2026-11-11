// Scouta market engine, Phase 2: multi-league player catalog via
// Sportmonks Football API v3, replacing the earlier API-Football plan
// (never deployed -- that plan's free tier capped at 100 req/day and
// only covered 2022-2024 seasons; this account's Sportmonks subscription
// is paid and far less constrained: 2,000+ requests/hour per entity).
//
// Design:
// - Fully subscription-driven: GET /football/leagues returns only the
//   leagues this account's plan actually includes, so this job never
//   hardcodes a league list. Add more leagues to the Sportmonks plan
//   later and this job picks them up on its next run with no code
//   change.
// - Insert-or-update via the upsert_sportmonks_player RPC (migration
//   0010), matched on players.api_player_id. On first insert,
//   current_price is seeded from rating (rating * 2, floor 10 SC) as a
//   reasoned starting point -- exactly like Phase 1's weights, not
//   empirically tuned. On every later run, current_price is left
//   untouched; this job only ever refreshes roster/rating metadata,
//   matching the FPL sync's philosophy that price only moves for a
//   specific reason, never silently alongside an unrelated refresh.
// - Sportmonks' `rating` statistic (type_id 118, "the player's match
//   ratings across the season") IS confirmed to be a 0-10-ish scale
//   (real run, 2026-11-10: raw values 5.7-7.5 across 330 players). A
//   flat x10 (the old API-Football-style treatment, tried first) was
//   wrong, not for the decode but for the spread: real season-average
//   ratings cluster far too tightly to differentiate the app's 40-99
//   tier system, so scaleRating() below rescales a reasoned realistic
//   range onto 40-99 instead of a flat x10. See its own comment.
// - Real users reported specific, verifiable cases of the opposite
//   problem: fringe players with only 1-2 appearances this season
//   landing at the TOP of the scale (94-99), above established regular
//   starters. Confirmed live (2026-11-11) against the real Sportmonks
//   API: this is because `rating` (type_id 118) is an unweighted
//   average with no reliability adjustment, so a 2-game fluke counts
//   the same as a 20-game season. shrinkRating() below pulls a raw
//   rating toward a league-average baseline proportional to how few
//   appearances (type_id 321, confirmed via the real /core/types
//   catalog) back it up, before scaleRating() runs.
// - position_id / detailed_position_id are decoded via a small hardcoded
//   table (only 16 values total, documented at
//   https://docs.sportmonks.com/v3/definitions/types/position-types),
//   not a runtime /core/types call -- simpler than API-Football's
//   approach and these IDs are stable, documented constants.
// - IS resumable across invocations via the `sync_state` table, capped
//   at TEAM_BUDGET teams per run. The original version of this file
//   assumed rate limits (2,000+ req/hour) were the only constraint and
//   tried the whole ~100-110 teams in one invocation -- wrong: Supabase
//   Edge Functions cap a single invocation at 150s wall-clock AND 2s of
//   actual CPU time (async I/O doesn't count, but JSON-parsing/iterating
//   every player's full statistics payload across 100+ teams does), and
//   that first version blew past one or both, hanging for ages and then
//   failing. Also scopes the `player.statistics` include to just the
//   current season (`playerStatisticSeasons` filter) instead of a
//   player's entire career, cutting payload size and CPU/parse cost
//   substantially. Call it repeatedly (or let the cron schedule call it
//   repeatedly) until a response says `"done": true`.
//
// Deploy: paste this file's contents into a new Edge Function named
// "sync-sportmonks-players" in the Supabase dashboard. Requires one
// secret: SPORTMONKS_API_TOKEN (Edge Functions -> Secrets). SUPABASE_URL
// and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const API_BASE = "https://api.sportmonks.com/v3/football";
const TEAM_BUDGET = 15; // teams processed per invocation; stays well under the 150s/2s-CPU per-invocation limits

// https://docs.sportmonks.com/v3/definitions/types/position-types
const POSITION_NAMES: Record<number, string> = {
  24: "Goalkeeper", 25: "Defender", 26: "Midfielder", 27: "Attacker", 28: "Unknown",
};
const DETAILED_POSITION_NAMES: Record<number, string> = {
  148: "Centre Back", 149: "Defensive Midfield", 150: "Attacking Midfield",
  151: "Centre Forward", 152: "Left Wing", 153: "Central Midfield",
  154: "Right Back", 155: "Left Back", 156: "Right Wing",
  157: "Left Midfield", 158: "Right Midfield", 163: "Secondary Striker",
};

const STAT_TYPE_RATING = 118;
// Confirmed live against the real Sportmonks /core/types catalog
// (2026-11-11), not guessed: id 119 is "Minutes Played", id 321 is
// "Appearances".
const STAT_TYPE_APPEARANCES = 321;

function num(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}

async function callApi(path: string, token: string, calls: { count: number }): Promise<any> {
  const url = `${API_BASE}${path}${path.includes("?") ? "&" : "?"}api_token=${token}`;
  calls.count++;
  const res = await fetch(url);
  const json = await res.json();
  if (!res.ok) {
    throw new Error(`Sportmonks ${path} returned ${res.status}: ${JSON.stringify(json).slice(0, 300)}`);
  }
  return json;
}

async function getState(supabase: ReturnType<typeof createClient>, key: string): Promise<number | null> {
  const { data } = await supabase.from("sync_state").select("value").eq("key", key).maybeSingle();
  return data ? (data as any).value : null;
}

async function setState(supabase: ReturnType<typeof createClient>, key: string, value: number) {
  await supabase.from("sync_state").upsert({ key, value, updated_at: new Date().toISOString() });
}

// Pulls the season-aggregate `rating` detail (type_id 118) and the
// season's appearance count (type_id 321) out of a player's `statistics`
// array for the given season_id, if present.
function extractRatingAndAppearances(
  statistics: any[],
  seasonId: number
): { rawRating: number | null; appearances: number } {
  const row = (statistics ?? []).find((s: any) => s.season_id === seasonId);
  if (!row) return { rawRating: null, appearances: 0 };
  const ratingDetail = (row.details ?? []).find((d: any) => d.type_id === STAT_TYPE_RATING);
  const rawRating = ratingDetail ? num(ratingDetail.value?.average) ?? num(ratingDetail.value?.total) : null;
  const appsDetail = (row.details ?? []).find((d: any) => d.type_id === STAT_TYPE_APPEARANCES);
  const appearances = num(appsDetail?.value?.total) ?? 0;
  return { rawRating, appearances };
}

// A player's `rating` from Sportmonks is a plain, unweighted average
// across however many matches they've played this season -- no
// adjustment for sample size. Confirmed live (2026-11-11): a fringe
// player with just 2 appearances (180 minutes) averaged 7.52, landing
// at the very top of the scale right alongside players with a full
// season's worth of appearances behind their average. Standard
// sports-analytics fix: shrink the raw rating toward a league-average
// baseline, proportional to how few appearances back it up, using a
// player with SHRINKAGE_GAMES "virtual" average appearances as the
// prior. A 2-appearance fluke gets pulled hard toward the baseline; an
// established 20+-appearance season barely moves.
const BASELINE_RAW_RATING = 6.6; // ~ median raw rating across the first real sync (p50 6.7-6.8)
const SHRINKAGE_GAMES = 10;

function shrinkRating(rawRating: number, appearances: number): number {
  return (rawRating * appearances + BASELINE_RAW_RATING * SHRINKAGE_GAMES) / (appearances + SHRINKAGE_GAMES);
}

// Confirmed against a real run (2026-11-10, 330 players across the 5
// subscribed leagues): raw season-average match ratings span roughly
// 5.7-7.5, clustering tightly (p10 6.5, p50 6.7, p90 7.1) -- a flat x10
// (the old API-Football-style treatment) compresses almost the entire
// roster into the app's lowest card tier ("sand", rating < 75), since
// real match-rating averages just don't spread anywhere near as wide as
// a 0-10 scale implies. RATING_LOW/HIGH are a reasoned domain estimate
// of the realistic range (replacement-level fringe player to a
// genuinely excellent season), not fitted to that one sample, so this
// should hold up as more players/seasons sync in. Not empirically
// tuned against actual tier distribution yet -- revisit if most players
// still end up bunched in one tier once there's a full dataset.
const RATING_LOW = 5.8;
const RATING_HIGH = 7.6;
const OUT_LOW = 42;
const OUT_HIGH = 96;

function scaleRating(raw: number): number {
  const t = (raw - RATING_LOW) / (RATING_HIGH - RATING_LOW);
  const scaled = OUT_LOW + t * (OUT_HIGH - OUT_LOW);
  return Math.max(40, Math.min(99, Math.round(scaled)));
}

Deno.serve(async () => {
  const token = Deno.env.get("SPORTMONKS_API_TOKEN");
  if (!token) {
    return new Response(JSON.stringify({ ok: false, reason: "SPORTMONKS_API_TOKEN secret not set" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const calls = { count: 0 };
  const log: string[] = [];
  let upserted = 0;
  const upsertErrors: string[] = [];

  try {
    // ---- Step 1: discover every league this subscription actually includes ----
    const leagues: { id: number; name: string; seasonId: number }[] = [];
    {
      let page = 1;
      let hasMore = true;
      while (hasMore) {
        const json = await callApi(`/leagues?include=currentSeason&per_page=50&page=${page}`, token, calls);
        for (const entry of json.data ?? []) {
          const season = entry.currentseason ?? entry.currentSeason ?? entry.current_season ?? null;
          if (!season?.id) {
            log.push(`League "${entry.name}" (id ${entry.id}) has no currentSeason -- skipped.`);
            continue;
          }
          leagues.push({ id: entry.id, name: entry.name, seasonId: season.id });
        }
        hasMore = !!json.pagination?.has_more;
        page++;
      }
    }
    log.push(`Discovered ${leagues.length} subscribed league(s): ${leagues.map((l) => l.name).join(", ")}`);

    // ---- Step 2: for each league, list its current season's teams ----
    const teams: { id: number; name: string; leagueName: string; seasonId: number }[] = [];
    for (const lg of leagues) {
      let page = 1;
      let hasMore = true;
      while (hasMore) {
        const json = await callApi(`/teams/seasons/${lg.seasonId}?per_page=50&page=${page}`, token, calls);
        for (const t of json.data ?? []) {
          teams.push({ id: t.id, name: t.name, leagueName: lg.name, seasonId: lg.seasonId });
        }
        hasMore = !!json.pagination?.has_more;
        page++;
      }
    }
    log.push(`Found ${teams.length} team(s) across those leagues.`);

    // ---- Step 3: resume cursor across teams, capped per invocation ----
    let teamIdx = (await getState(supabase, "sm_cursor_team_idx")) ?? 0;
    const budgetEnd = Math.min(teamIdx + TEAM_BUDGET, teams.length);

    for (; teamIdx < budgetEnd; teamIdx++) {
      const team = teams[teamIdx];
      const json = await callApi(
        `/squads/teams/${team.id}?include=player.statistics.details;player.nationality;player.position` +
          `&filters=playerStatisticSeasons:${team.seasonId}`,
        token,
        calls
      );
      const rows: any[] = json.data ?? [];

      for (const row of rows) {
        const p = row.player;
        if (!p) continue;

        const { rawRating, appearances } = extractRatingAndAppearances(p.statistics, team.seasonId);
        const shrunkRating = rawRating !== null ? shrinkRating(rawRating, appearances) : null;
        const rating100 = shrunkRating !== null ? scaleRating(shrunkRating) : null;
        const seedPrice = rating100 !== null ? Math.max(10, Math.round(rating100 * 2)) : 10;

        const positionName =
          DETAILED_POSITION_NAMES[row.detailed_position_id] ??
          POSITION_NAMES[p.position_id ?? row.position_id] ??
          null;

        const { error } = await supabase.rpc("upsert_sportmonks_player", {
          p_api_player_id: p.id,
          p_name: p.display_name ?? p.name ?? p.common_name,
          p_full_name: [p.firstname, p.lastname].filter(Boolean).join(" ") || p.name,
          p_age: p.date_of_birth
            ? Math.floor((Date.now() - new Date(p.date_of_birth).getTime()) / (365.25 * 24 * 3600 * 1000))
            : null,
          p_date_of_birth: p.date_of_birth ?? null,
          p_nationality: p.nationality?.iso2 ?? null,
          p_photo_url: p.image_path ?? null,
          p_position: positionName,
          p_club: team.name,
          p_league: team.leagueName,
          p_rating: rating100,
          p_seed_price: seedPrice,
        });
        if (error) {
          upsertErrors.push(`player ${p.id}: ${error.message}`);
        } else {
          upserted++;
        }
      }

      await setState(supabase, "sm_cursor_team_idx", teamIdx + 1);
    }

    const done = teamIdx >= teams.length;
    if (done) {
      // Full pass finished -- reset the cursor so the next scheduled run
      // starts a fresh pass (this job refreshes ratings/rosters on every
      // full pass, it doesn't "finish" once like the old plan's
      // budget-limited seeding did).
      await setState(supabase, "sm_cursor_team_idx", 0);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        done,
        upserted_this_run: upserted,
        teams_total: teams.length,
        resumed_at_team_idx: teamIdx,
        api_calls_this_run: calls.count,
        upsert_error_count: upsertErrors.length,
        upsert_errors: upsertErrors.slice(0, 20),
        log,
        note: done
          ? "Full pass across all teams complete."
          : `Budget reached for this run -- call again (${teams.length - teamIdx} team(s) left) to continue.`,
      }),
      { headers: { "Content-Type": "application/json" } }
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ ok: false, reason: String(e), api_calls_this_run: calls.count, log }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});
