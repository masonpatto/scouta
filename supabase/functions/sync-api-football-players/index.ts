// Scouta market engine, Phase 2: multi-league player catalog via
// API-Football's free tier (100 req/day, 10 req/min).
//
// Design:
// - Insert-or-update, matched by players.api_player_id (upsert). Unlike
//   sync-fpl-prices (update-only against an already-seeded roster), this
//   job is the one doing the roster seeding for non-Premier-League
//   players -- the 746 non-PL rows already in the table are untouched
//   placeholder data; this inserts fresh, real rows alongside them.
// - Resumable across runs via the `sync_state` table (already in the
//   schema, previously unused). One run processes a fixed request
//   budget (REQUEST_BUDGET, comfortably under the 100/day cap) and
//   picks up exactly where the last run left off -- so on the free
//   tier, fully populating the top 5 European leagues (~2,500-3,000
//   players) takes several daily runs, not one.
// - League IDs are resolved by name+country at runtime (via
//   /leagues?name=&country=) and cached in sync_state, rather than
//   hardcoded -- avoids silently fetching nothing if an assumed numeric
//   ID turns out to be wrong.
// - `current_price` has no API-Football equivalent, so it's seeded
//   once from `rating` (rating * 2, floor 5 SC) as a reasoned starting
//   point -- exactly like Phase 1's weights, not empirically tuned.
//   Nothing re-derives price from rating after this one-time seed;
//   that stays an evidence-only concern for a future price-sync job.
//
// Deploy: paste this file's contents into a new Edge Function named
// "sync-api-football-players" in the Supabase dashboard. Requires one
// secret: API_FOOTBALL_KEY (Edge Functions -> Secrets). SUPABASE_URL
// and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const API_BASE = "https://v3.football.api-sports.io";
const REQUEST_BUDGET = 85; // per invocation; stays well under the 100/day free cap
const FREE_TIER_MAX_SEASON = 2024; // free plan only covers 2022-2024; ratings/rosters are from that season, not live-current
const PAGE_SIZE_NOTE = "API-Football paginates /players at a fixed page size set by them, not by us.";

// Target competitions. Resolved to numeric league IDs + current season
// on first run and cached in sync_state, rather than hardcoded --
// numeric IDs found in blog posts/forums aren't authoritative.
const TARGET_LEAGUES = [
  { key: "premier_league", name: "Premier League", country: "England" },
  { key: "la_liga", name: "La Liga", country: "Spain" },
  { key: "bundesliga", name: "Bundesliga", country: "Germany" },
  { key: "serie_a", name: "Serie A", country: "Italy" },
  { key: "ligue_1", name: "Ligue 1", country: "France" },
];

// Country name (as API-Football returns it) -> ISO 3166-1 alpha-2, for
// the app's existing flagEmoji(code). Covers the nationalities expected
// across Europe's top 5 leagues; anything unmapped just renders no flag
// rather than crashing.
const COUNTRY_TO_ISO: Record<string, string> = {
  England: "GB", Spain: "ES", Germany: "DE", Italy: "IT", France: "FR",
  Portugal: "PT", Netherlands: "NL", Belgium: "BE", Brazil: "BR",
  Argentina: "AR", Uruguay: "UY", Colombia: "CO", Chile: "CL", Peru: "PE",
  Croatia: "HR", Serbia: "RS", Poland: "PL", Austria: "AT", Switzerland: "CH",
  Denmark: "DK", Sweden: "SE", Norway: "NO", Finland: "FI", Iceland: "IS",
  Ireland: "IE", Wales: "WA", Scotland: "SCT", Turkey: "TR", Greece: "GR",
  Morocco: "MA", Algeria: "DZ", Tunisia: "TN", Senegal: "SN", Ghana: "GH",
  Nigeria: "NG", Ivory_Coast: "CI", "Côte d'Ivoire": "CI", Cameroon: "CM",
  Egypt: "EG", Mali: "ML", Japan: "JP", "South Korea": "KR", Korea_Republic: "KR",
  Australia: "AU", USA: "US", "United States": "US", Canada: "CA", Mexico: "MX",
  Ecuador: "EC", Paraguay: "PY", Venezuela: "VE", Bosnia: "BA",
  "Bosnia and Herzegovina": "BA", Slovenia: "SI", Slovakia: "SK",
  "Czech Republic": "CZ", Czechia: "CZ", Hungary: "HU", Romania: "RO",
  Ukraine: "UA", Russia: "RU", Georgia: "GE", Albania: "AL",
  "North Macedonia": "MK", Montenegro: "ME", Kosovo: "XK", Israel: "IL",
  "Cape Verde": "CV", Gabon: "GA", "DR Congo": "CD", Guinea: "GN",
  "Burkina Faso": "BF", Mozambique: "MZ", Jamaica: "JM", Curacao: "CW",
  "New Zealand": "NZ", China: "CN", Iran: "IR", Qatar: "QA",
  "Saudi Arabia": "SA", Panama: "PA", "Costa Rica": "CR",
};

function num(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}

async function callApi(path: string, key: string, calls: { count: number }): Promise<any> {
  calls.count++;
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { "x-apisports-key": key },
  });
  if (!res.ok) {
    throw new Error(`API-Football ${path} returned ${res.status}`);
  }
  const json = await res.json();
  if (json.errors && Array.isArray(json.errors) ? json.errors.length : Object.keys(json.errors || {}).length) {
    throw new Error(`API-Football ${path} errors: ${JSON.stringify(json.errors)}`);
  }
  return json;
}

async function getState(supabase: ReturnType<typeof createClient>, key: string): Promise<number | null> {
  const { data } = await supabase.from("sync_state").select("value").eq("key", key).maybeSingle();
  return data ? data.value : null;
}

async function setState(supabase: ReturnType<typeof createClient>, key: string, value: number) {
  await supabase.from("sync_state").upsert({ key, value, updated_at: new Date().toISOString() });
}

Deno.serve(async () => {
  const apiKey = Deno.env.get("API_FOOTBALL_KEY");
  if (!apiKey) {
    return new Response(JSON.stringify({ ok: false, reason: "API_FOOTBALL_KEY secret not set" }), {
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

  try {
    // ---- Step 1: resolve league IDs + current season once, cache in sync_state ----
    const resolved: { key: string; id: number; season: number }[] = [];
    for (const lg of TARGET_LEAGUES) {
      const cachedId = await getState(supabase, `af_league_${lg.key}_id`);
      const cachedSeason = await getState(supabase, `af_league_${lg.key}_season`);
      if (cachedId !== null && cachedSeason !== null) {
        resolved.push({ key: lg.key, id: cachedId, season: cachedSeason });
        continue;
      }
      if (calls.count >= REQUEST_BUDGET) break;
      const json = await callApi(`/leagues?name=${encodeURIComponent(lg.name)}&country=${encodeURIComponent(lg.country)}`, apiKey, calls);
      const entry = (json.response ?? [])[0];
      if (!entry) {
        log.push(`Could not resolve league "${lg.name}" (${lg.country}) -- check the name/country match API-Football's data.`);
        continue;
      }
      // The free tier only has access to seasons 2022-2024 (not whatever
      // API-Football calls "current"), so pick the newest season at or
      // below that ceiling rather than trusting the current:true flag.
      const eligibleYears = (entry.seasons ?? [])
        .map((s: any) => s.year)
        .filter((y: number) => y <= FREE_TIER_MAX_SEASON)
        .sort((a: number, b: number) => b - a);
      const currentSeason = eligibleYears[0];
      if (!currentSeason) {
        log.push(`Resolved league "${lg.name}" to id ${entry.league.id} but found no season <= ${FREE_TIER_MAX_SEASON}.`);
        continue;
      }
      await setState(supabase, `af_league_${lg.key}_id`, entry.league.id);
      await setState(supabase, `af_league_${lg.key}_season`, currentSeason);
      resolved.push({ key: lg.key, id: entry.league.id, season: currentSeason });
      log.push(`Resolved "${lg.name}" -> league id ${entry.league.id}, season ${currentSeason}`);
    }

    // ---- Step 2: resume cursor (which league index + page we're on) ----
    let leagueIdx = (await getState(supabase, "af_cursor_league_idx")) ?? 0;
    let page = (await getState(supabase, "af_cursor_page")) ?? 1;

    while (leagueIdx < TARGET_LEAGUES.length && calls.count < REQUEST_BUDGET) {
      const lg = TARGET_LEAGUES[leagueIdx];
      const r = resolved.find((x) => x.key === lg.key);
      if (!r) {
        // couldn't resolve this league above (budget ran out, or name mismatch) -- skip it
        leagueIdx++;
        page = 1;
        continue;
      }

      const json = await callApi(`/players?league=${r.id}&season=${r.season}&page=${page}`, apiKey, calls);
      const rows: any[] = json.response ?? [];
      const totalPages: number = json.paging?.total ?? 1;

      if (rows.length > 0) {
        const records = rows.map((row: any) => {
          const p = row.player;
          const stat = (row.statistics ?? [])[0];
          const rawRating = num(stat?.games?.rating);
          const rating100 = rawRating !== null ? Math.max(40, Math.min(99, Math.round(rawRating * 10))) : null;
          const isoCode = COUNTRY_TO_ISO[p.nationality] ?? null;
          return {
            api_player_id: p.id,
            name: p.name,
            full_name: [p.firstname, p.lastname].filter(Boolean).join(" ") || p.name,
            age: p.age ?? null,
            date_of_birth: p.birth?.date ?? null,
            nationality: isoCode,
            photo_url: p.photo ?? null,
            position: stat?.games?.position ?? null,
            club: stat?.team?.name ?? null,
            league: lg.name,
            rating: rating100,
            current_price: rating100 !== null ? Math.max(5, Math.round(rating100 * 2)) : 10,
            active: true,
          };
        });

        const { error } = await supabase
          .from("players")
          .upsert(records, { onConflict: "api_player_id" });
        if (error) {
          log.push(`Upsert error on ${lg.name} page ${page}: ${error.message}`);
        } else {
          upserted += records.length;
        }
      }

      if (page >= totalPages) {
        leagueIdx++;
        page = 1;
        log.push(`Finished "${lg.name}" (${totalPages} pages).`);
      } else {
        page++;
      }
    }

    await setState(supabase, "af_cursor_league_idx", leagueIdx);
    await setState(supabase, "af_cursor_page", page);

    const done = leagueIdx >= TARGET_LEAGUES.length;
    return new Response(
      JSON.stringify({
        ok: true,
        done,
        upserted_this_run: upserted,
        api_calls_this_run: calls.count,
        resumed_at: { league: TARGET_LEAGUES[leagueIdx]?.key ?? null, page },
        log,
        note: done
          ? "All target leagues fully synced."
          : "Budget reached for this run -- call again (or wait for the next scheduled run) to continue from where this left off.",
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
