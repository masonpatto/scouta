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
// Rating pipeline (REWRITTEN 2026-11-11, several times, after real,
// user-caught failures -- the history matters for whoever touches this
// next, because it explains why the final design is deliberately
// SIMPLE rather than a bigger stats model):
// 1. Sportmonks' own `rating` stat (type_id 118) is a single unweighted
//    per-match average with no reliability adjustment, and, separately
//    from sample size, doesn't track real-world reputation at all: a
//    very good player at a mid-table club (lots of individual defensive/
//    passing actions in a possession-heavy system) can out-rate an
//    established star at a much bigger club. Relying on it alone was
//    the first failure (fringe 2-game players hitting the scale
//    ceiling), fixed with reliability shrinkage.
// 2. A from-scratch replacement built on 8 per-90 underlying stats
//    (goals, tackles, key passes, clearances, aerials, etc.) was tried
//    next, to fix the mid-table-vs-big-club gap -- but it kept
//    reintroducing new bugs, one stat at a time: a 2-game defender's
//    "11.5 clearances per 90" blew through the ceiling because it
//    wasn't shrunk like the rating was; after fixing that, a 12-game
//    super-sub's goals/assists rate (inflated by never playing a full
//    90) did the same thing because shrinkage used appearance count
//    instead of minutes; a THIRD player then surfaced yet another
//    per-90 anomaly on a different stat. With ~2,800 players and 8
//    independent per-90 inputs, there will always be another player
//    with a freak number on SOME stat -- this doesn't converge by
//    patching one input at a time.
// 3. Drop the custom production score entirely. The only inputs are
//    Sportmonks' own `rating` (shrunk toward a baseline by
//    games-equivalent playing time, so a tiny sample can't dominate), a
//    small bonus for a short list of genuinely elite clubs (gated on
//    actually having played, not just being on the books), and a
//    league-strength multiplier. Far fewer moving parts -- one external
//    signal instead of nine -- so far fewer ways for one unusual player
//    to break it. Validated against real, named players (Rice,
//    Fernandes, Haaland, Van Dijk, Groß, a 2-game fringe defender, a
//    real super-sub) via a throwaway debug Edge Function before this
//    went live; see scaleRating()'s own comment for the resulting
//    numbers.
// 4. Point 3 fixed mid-table-out-rates-big-club, but the INVERSE still
//    got through live: a Centre Back landed at 93 (above Van Dijk's
//    validated 87) and a Defensive Midfielder at a relegation-battling
//    Serie A side landed at 90 (level with Haaland/Rice) -- Sportmonks'
//    per-match rating still rewards raw defensive-action volume well
//    beyond real-world reputation, untouched by points 1-3. Added two
//    narrow, one-directional ceilings (clip down only, never raise) --
//    see the comment right above computeRating() for the detail -- plus
//    a genuine bug fix found along the way: three ELITE_CLUBS entries
//    were spelled in a way Sportmonks never actually returns, so those
//    clubs' players silently never got the elite bonus at all.
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
// Only rating/minutes are used now -- see the rating-pipeline comment
// above for why the other per-90 stats were dropped entirely.
const STAT = {
  RATING: 118, MINUTES: 119,
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
// Spellings confirmed against this project's own live `players.club`
// values (2026-11-12), not assumed -- three of these (Barcelona, Bayern
// Munich, Atlético Madrid) were previously spelled in a way Sportmonks
// never actually returns, so those three clubs' players silently never
// got the elite bonus at all. Found while investigating the rating
// overhaul below; fixed as part of the same pass since it's the same
// root cause (reputation signal not reaching the formula correctly).
const ELITE_CLUBS = new Set([
  "Manchester City", "Arsenal", "Liverpool", "Manchester United", "Chelsea", "Tottenham Hotspur",
  "Real Madrid", "FC Barcelona", "Atlético de Madrid",
  "FC Bayern München", "Borussia Dortmund",
  "Juventus", "Inter", "AC Milan", "Napoli",
]);
const ELITE_CLUB_BONUS = 0.3;
// A fringe squad player who's barely featured this season shouldn't
// inherit a big club's reputation bonus just for being on the books --
// gated on games-equivalent (minutes / 90), same reasoning as the
// shrinkage fix below: raw appearance count alone would let a
// super-sub qualify despite barely playing.
const MIN_GAMES_FOR_ELITE_BONUS = 5;

// A player's `rating` from Sportmonks is a plain, unweighted average
// across however many matches they've played this season -- no
// adjustment for sample size. Confirmed live (2026-11-11): a fringe
// player with just 2 appearances (180 minutes) averaged 7.52, landing
// at the very top of the scale right alongside players with a full
// season's worth of appearances behind their average. Standard
// sports-analytics fix: shrink the raw rating toward a baseline,
// proportional to how little playing time backs it up, using a player
// with SHRINKAGE_GAMES "virtual" average games as the prior.
//
// Reliability is measured by MINUTES (games-equivalent = minutes / 90),
// not raw appearance count -- confirmed live that raw appearance count
// let a super-sub through: a player with 12 appearances but only 475
// minutes (~5.3 full matches, ~40 min/appearance) looked just as
// "reliable" as a 12-game starter. For a genuine starter the two
// numbers are nearly identical anyway, so this only changes anything
// for exactly the super-sub case it's meant to.
const BASELINE_RAW_RATING = 6.6; // ~ median raw Sportmonks rating across the first real sync
const SHRINKAGE_GAMES = 10;
function shrink(value: number, baseline: number, gamesEquivalent: number): number {
  return (value * gamesEquivalent + baseline * SHRINKAGE_GAMES) / (gamesEquivalent + SHRINKAGE_GAMES);
}

// Pulls the season-aggregate `rating` detail (type_id 118) out of a
// player's `statistics` array for the given season_id, if present.
// Reliability is handled by minutes played (see shrink()'s comment),
// not appearance count, so that's not extracted here.
function extractRating(statistics: any[], seasonId: number): number | null {
  const row = (statistics ?? []).find((s: any) => s.season_id === seasonId);
  if (!row) return null;
  const details = row.details ?? [];
  const ratingValue = statRaw(details, STAT.RATING);
  return num(ratingValue?.average) ?? num(ratingValue?.total);
}

// Calibrated against real, named players via a throwaway debug function
// before going live (2026-11-11): with this (final, deliberately simple)
// design, Fernandes lands at 91, Rice/Haaland at 90, Van Dijk at 87,
// Groß (very good, NOT a big-club player) at 82 -- clearly below the
// big-club regulars rather than level with them -- a 2-appearance
// fringe defender at 73, and a real super-sub at 71.
const RATING_LOW = 5.8;
const RATING_HIGH = 7.55;
const OUT_LOW = 42;
const OUT_HIGH = 99;

function scaleRating(raw: number): number {
  const t = (raw - RATING_LOW) / (RATING_HIGH - RATING_LOW);
  const scaled = OUT_LOW + t * (OUT_HIGH - OUT_LOW);
  return Math.max(40, Math.min(99, Math.round(scaled)));
}

// Rating pipeline, point 4 (2026-11-12): the design above (point 3)
// fixed the "mid-table player out-rates a big-club star" case, but two
// real, user-caught outliers showed the INVERSE failure survives it --
// Sportmonks' per-match rating still rewards raw defensive-action
// volume (clearances, blocks, interceptions, aerial duels) far more
// generously than real-world reputation justifies, with nothing in the
// pipeline to catch it:
//   - A Centre Back at a Premier League club landed at 93 -- above
//     Van Dijk's validated 87 -- despite no real-world case for being
//     rated above him.
//   - A Defensive Midfielder at a relegation-battling Serie A side
//     (Frosinone, not remotely an elite club) landed at 90, level with
//     Haaland/Rice.
// Two narrow, ONE-DIRECTIONAL ceilings (they only ever clip a rating
// down, never raise one, so every already-validated named player above
// is unaffected unless they were already at/above the ceiling):
//   1. 88+ is reserved for players with an actual reputation signal
//      (elite-club minutes, same ELITE_CLUBS/MIN_GAMES_FOR_ELITE_BONUS
//      gate as the bonus above) -- an obscure mid-table player's raw
//      stats alone can no longer buy a top-tier rating.
//   2. Pure defensive positions (Centre Back, Full Back) additionally
//      cap a couple of points lower, regardless of club, since that's
//      specifically where the defensive-action-volume bias shows up.
//      Defensive Midfield is deliberately NOT included here -- a
//      genuinely elite deep-lying playmaker (a Rodri, a Kimmich) can
//      legitimately earn a rating up there and shouldn't be clipped
//      alongside the obscure case above, which the non-elite ceiling
//      already catches on its own.
const NON_ELITE_RATING_CEILING = 87;
const DEFENSIVE_POSITION_RATING_CEILING = 88;
const DEFENSIVE_POSITIONS = new Set(["Centre Back", "Left Back", "Right Back"]);

function computeRating(
  rawRating: number | null,
  minutes: number,
  club: string,
  leagueName: string,
  positionName: string | null
): number {
  const gamesEquivalent = minutes / 90;
  const shrunkRating = rawRating !== null ? shrink(rawRating, BASELINE_RAW_RATING, gamesEquivalent) : BASELINE_RAW_RATING;
  const isElite = ELITE_CLUBS.has(club) && gamesEquivalent >= MIN_GAMES_FOR_ELITE_BONUS;
  const eliteBonus = isElite ? ELITE_CLUB_BONUS : 0;
  const strength = leagueStrength(leagueName);
  const finalRaw = (shrunkRating + eliteBonus) * strength + (1 - strength) * BASELINE_RAW_RATING;
  let rating = scaleRating(finalRaw);
  if (!isElite) rating = Math.min(rating, NON_ELITE_RATING_CEILING);
  if (positionName && DEFENSIVE_POSITIONS.has(positionName)) {
    rating = Math.min(rating, DEFENSIVE_POSITION_RATING_CEILING);
  }
  return rating;
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

        // No statRow at all (confirmed live, 2026-11-11: e.g. a long-term
        // injury with zero appearances this season) isn't a different case
        // from a thin sample -- it's just the zero-games extreme of it, so
        // it goes through the exact same shrink-toward-baseline formula
        // instead of a separate hardcoded fallback number. rawRating/minutes
        // naturally come out null/0 and shrink() pulls that all the way to
        // BASELINE_RAW_RATING, scaled by the same league-strength logic as
        // every other player.
        const statRow = (p.statistics ?? []).find((s: any) => s.season_id === team.seasonId);
        const details = statRow?.details ?? [];
        const rawRating = extractRating(p.statistics, team.seasonId);
        const minutes = statTotal(details, STAT.MINUTES);
        const rating100 = computeRating(rawRating, minutes, team.name, team.leagueName, positionName);
        const seedPrice = Math.max(10, Math.round(rating100 * 2));

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
