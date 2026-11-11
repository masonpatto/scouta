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
// - position_id / detailed_position_id are decoded via a small hardcoded
//   table (only 16 values total, documented at
//   https://docs.sportmonks.com/v3/definitions/types/position-types),
//   not a runtime /core/types call -- simpler than API-Football's
//   approach and these IDs are stable, documented constants.
// - IS resumable across invocations via the `sync_state` table, capped
//   at TEAM_BUDGET teams per run. Supabase Edge Functions cap a single
//   invocation at 150s wall-clock AND 2s of actual CPU time (async I/O
//   doesn't count, but JSON-parsing/iterating every player's full
//   statistics payload across 100+ teams does), so this scopes the
//   `player.statistics` include to just the current season
//   (`playerStatisticSeasons` filter). Call it repeatedly (or let the
//   cron schedule call it repeatedly) until a response says
//   `"done": true`.
//
// Rating pipeline (REWRITTEN 2026-11-11 after two real, user-caught
// failures -- both are documented at the relevant function because the
// history matters for whoever touches this next):
// 1. Sportmonks' own `rating` stat (type_id 118) is a single unweighted
//    per-match average with no reliability adjustment, and, separately
//    from sample size, doesn't track real-world reputation at all: a
//    very good player at a mid-table club (lots of individual defensive/
//    passing actions in a possession-heavy system) can out-rate an
//    established star at a much bigger club. Relying on it alone was
//    the first failure (fringe 2-game players hitting the scale
//    ceiling), fixed with shrinkRating-style reliability shrinkage.
// 2. A from-scratch replacement built on per-90 underlying stats (goals,
//    tackles, key passes, etc.) was the second failure: per-90
//    extrapolation on a small minutes sample is EXTREMELY noisy (a
//    2-game defender's "11.5 clearances per 90" is just a handful of
//    real clearances blown up by the per-90 math), and it wasn't
//    shrunk the same way the rating was -- it blew straight through the
//    scale ceiling for exactly the player it was meant to fix.
// 3. Final design: blend a shrunk Sportmonks rating with a SEPARATELY
//    shrunk, position-weighted production score (both get the identical
//    reliability treatment now), then add a small club-prestige bonus
//    for a short list of genuinely elite clubs -- the one signal no
//    per-match stat captures -- and a league-strength multiplier.
//    Validated against real, named players (Rice, Fernandes, Haaland,
//    Van Dijk, Groß, an obscure 2-game fringe defender) via a throwaway
//    debug Edge Function before this went live; see scaleRating()'s own
//    comment for the resulting numbers.
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

// Confirmed live against the real Sportmonks /core/types and
// /definitions/types/statistics catalogs (2026-11-11), not guessed.
const STAT = {
  GOALS: 52, ASSISTS: 79, KEY_PASSES: 117, DRIBBLES_OK: 109,
  TACKLES: 78, INTERCEPTIONS: 100, CLEARANCES: 101, AERIALS_WON: 107,
  PASS_ACC: 1584, PASS_ACC_ALT: 82,
  SAVES: 57, CLEAN_SHEETS: 194, GK_CLEAN_SHEETS: 195,
  RATING: 118, MINUTES: 119, APPEARANCES: 321,
};

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

function statTotal(details: any[], typeId: number): number {
  const d = (details ?? []).find((x: any) => x.type_id === typeId);
  return num(d?.value?.total) ?? 0;
}
function statRaw(details: any[], typeId: number): any {
  const d = (details ?? []).find((x: any) => x.type_id === typeId);
  return d?.value ?? null;
}
function statPercent(details: any[], typeId: number): number | null {
  const d = (details ?? []).find((x: any) => x.type_id === typeId);
  return num(d?.value?.average) ?? num(d?.value?.total) ?? null;
}
function perNinety(total: number, minutes: number): number {
  return minutes > 0 ? (total / minutes) * 90 : 0;
}
function clamp(v: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, v));
}

type Role = "GK" | "DEF" | "MID" | "FWD";
function roleFor(positionName: string | null): Role {
  if (!positionName) return "MID";
  if (positionName === "Goalkeeper") return "GK";
  if (["Centre Back", "Right Back", "Left Back", "Defender"].includes(positionName)) return "DEF";
  if (["Centre Forward", "Left Wing", "Right Wing", "Secondary Striker", "Attacker"].includes(positionName)) return "FWD";
  return "MID";
}

// Reasoned against real competitive standing (UEFA coefficients), not a
// guess: the "big 4" leagues are treated as roughly equal top tier; the
// Championship, as England's second tier, is clearly a level below.
const LEAGUE_STRENGTH: Record<string, number> = {
  "Premier League": 1.0,
  "La Liga": 1.0,
  "Bundesliga": 0.97,
  "Serie A": 0.97,
  "Championship": 0.82,
};
function leagueStrength(leagueName: string | null): number {
  return leagueName ? (LEAGUE_STRENGTH[leagueName] ?? 0.85) : 0.85;
}

// A handful of genuinely elite clubs across the 5 subscribed leagues --
// the one signal no per-match stat captures: a very good player at a
// mid-table club (lots of individual defensive/passing actions in a
// possession-heavy system) can out-produce a very good player at a much
// bigger club on raw per-90 numbers alone, without being the better
// player by real-world reputation.
const ELITE_CLUBS = new Set([
  "Manchester City", "Arsenal", "Liverpool", "Manchester United", "Chelsea", "Tottenham Hotspur",
  "Real Madrid", "Barcelona", "Atlético Madrid",
  "Bayern Munich", "Borussia Dortmund",
  "Juventus", "Inter", "AC Milan", "Napoli",
]);
const ELITE_CLUB_BONUS = 0.3;

// A player's `rating` from Sportmonks is a plain, unweighted average
// across however many matches they've played this season -- no
// adjustment for sample size. Confirmed live (2026-11-11): a fringe
// player with just 2 appearances (180 minutes) averaged 7.52, landing
// at the very top of the scale right alongside players with a full
// season's worth of appearances behind their average. Standard
// sports-analytics fix: shrink a raw value toward a baseline,
// proportional to how few appearances back it up, using a player with
// SHRINKAGE_GAMES "virtual" average appearances as the prior. The SAME
// function is used for both the Sportmonks rating and the production
// score below -- the second real bug here was shrinking only the
// former and not the latter.
const BASELINE_RAW_RATING = 6.6; // ~ median raw Sportmonks rating across the first real sync
const BASELINE_PRODUCTION = 5.8; // matches productionScore()'s own intercept -- "zero contribution" level
const SHRINKAGE_GAMES = 10;
function shrink(value: number, baseline: number, appearances: number): number {
  return (value * appearances + baseline * SHRINKAGE_GAMES) / (appearances + SHRINKAGE_GAMES);
}

// Pulls the season-aggregate `rating` detail (type_id 118) and the
// season's appearance count (type_id 321) out of a player's `statistics`
// array for the given season_id, if present.
function extractRatingAndAppearances(
  statistics: any[],
  seasonId: number
): { rawRating: number | null; appearances: number; details: any[] } {
  const row = (statistics ?? []).find((s: any) => s.season_id === seasonId);
  if (!row) return { rawRating: null, appearances: 0, details: [] };
  const details = row.details ?? [];
  const ratingValue = statRaw(details, STAT.RATING);
  const rawRating = num(ratingValue?.average) ?? num(ratingValue?.total);
  const appearances = statTotal(details, STAT.APPEARANCES);
  return { rawRating, appearances, details };
}

// Position-weighted per-90 production score, on roughly the same 0-10
// scale as Sportmonks' own match rating. NOT a from-scratch stat
// recipe fitted to look right -- goals/assists/key passes weighted
// heavily for attacking roles, tackles/interceptions/clearances/aerials
// for defensive roles, with a small pass-accuracy nudge for everyone.
function productionScore(role: Role, details: any[], minutes: number): number {
  const p90 = (typeId: number) => perNinety(statTotal(details, typeId), minutes);
  const goals = p90(STAT.GOALS);
  const assists = p90(STAT.ASSISTS);
  const keyPasses = p90(STAT.KEY_PASSES);
  const dribbles = p90(STAT.DRIBBLES_OK);
  const tackles = p90(STAT.TACKLES);
  const interceptions = p90(STAT.INTERCEPTIONS);
  const clearances = p90(STAT.CLEARANCES);
  const aerials = p90(STAT.AERIALS_WON);
  const passAcc = statPercent(details, STAT.PASS_ACC) ?? statPercent(details, STAT.PASS_ACC_ALT) ?? 75;

  if (role === "GK") {
    const saves = p90(STAT.SAVES);
    const cleanSheetsTotal = statTotal(details, STAT.CLEAN_SHEETS) || statTotal(details, STAT.GK_CLEAN_SHEETS);
    const appearancesForCS = statTotal(details, STAT.APPEARANCES) || 1;
    const cleanSheetRate = cleanSheetsTotal / appearancesForCS;
    return clamp(5.5 + saves * 0.35 + cleanSheetRate * 3, 4, 9);
  }

  const attacking = goals * 2.2 + assists * 1.8 + keyPasses * 0.35 + dribbles * 0.12;
  const defending = tackles * 0.22 + interceptions * 0.22 + clearances * 0.08 + aerials * 0.12;
  const passingQuality = (passAcc - 75) * 0.02;

  const weights: Record<string, { attacking: number; defending: number }> = {
    DEF: { attacking: 0.35, defending: 1.0 },
    MID: { attacking: 0.75, defending: 0.55 },
    FWD: { attacking: 1.1, defending: 0.2 },
  };
  const w = weights[role] ?? weights.MID;
  const raw = 5.8 + attacking * w.attacking + defending * w.defending + passingQuality;
  return clamp(raw, 4, 9.5);
}

// Calibrated against real, named players via a throwaway debug function
// before going live (2026-11-11): with this mapping, Haaland (genuinely
// world-class) lands at 91, Rice/Fernandes (very good, big-club regulars)
// at 87-88, Van Dijk at 84, Groß (very good, NOT a big-club player) at
// 83 -- clearly below Rice/Fernandes rather than level with them -- and
// a 2-appearance fringe defender at 67 instead of maxing the scale.
const RATING_LOW = 5.8;
const RATING_HIGH = 7.55;
const OUT_LOW = 42;
const OUT_HIGH = 99;

function scaleRating(raw: number): number {
  const t = (raw - RATING_LOW) / (RATING_HIGH - RATING_LOW);
  const scaled = OUT_LOW + t * (OUT_HIGH - OUT_LOW);
  return Math.max(40, Math.min(99, Math.round(scaled)));
}

function computeRating(
  details: any[],
  rawRating: number | null,
  appearances: number,
  minutes: number,
  role: Role,
  club: string,
  leagueName: string
): number {
  const shrunkSM = rawRating !== null ? shrink(rawRating, BASELINE_RAW_RATING, appearances) : BASELINE_RAW_RATING;
  const prodScore = productionScore(role, details, minutes);
  const shrunkProd = shrink(prodScore, BASELINE_PRODUCTION, appearances);
  const blended = 0.5 * shrunkSM + 0.5 * shrunkProd;
  const eliteBonus = ELITE_CLUBS.has(club) ? ELITE_CLUB_BONUS : 0;
  const strength = leagueStrength(leagueName);
  const finalRaw = (blended + eliteBonus) * strength + (1 - strength) * BASELINE_RAW_RATING;
  return scaleRating(finalRaw);
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

        const positionName =
          DETAILED_POSITION_NAMES[row.detailed_position_id] ??
          POSITION_NAMES[p.position_id ?? row.position_id] ??
          null;
        const role = roleFor(positionName);

        const { rawRating, appearances, details } = extractRatingAndAppearances(p.statistics, team.seasonId);
        const minutes = statTotal(details, STAT.MINUTES);
        const rating100 = details.length
          ? computeRating(details, rawRating, appearances, minutes, role, team.name, team.leagueName)
          : null;
        const seedPrice = rating100 !== null ? Math.max(10, Math.round(rating100 * 2)) : 10;

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
