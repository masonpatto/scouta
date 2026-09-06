// Scouta market engine, Phase 1: Premier League prices driven by the free
// Fantasy Premier League API (no key required). Runs daily via pg_cron
// (see the cron setup SQL in docs/market-engine.md).
//
// Design:
// - Update-only, matched by players.fpl_id. Never inserts new players --
//   roster seeding is a separate concern from daily price-driving sync.
// - Price only moves on genuine evidence accumulated *since the last
//   sync*: FPL points scored, underlying expected-goal-involvement
//   change, minutes played, and injury-doubt status changing. It never
//   looks at FPL's own now_cost (that reflects FPL-manager transfer
//   hype, not Scouta evidence) and never looks at Scouta's own `rating`/
//   Potential field.
// - Every move is hard-capped at +/-15%; a quiet day with no evidence
//   moves nothing (below MIN_MOVE_PCT, the price is left untouched).
// - The weights below are a reasoned v1 starting point, not empirically
//   tuned -- expect to revisit them after watching a few real gameweeks.
//
// Deploy: paste this file's contents into a new Edge Function named
// "sync-fpl-prices" in the Supabase dashboard and deploy. SUPABASE_URL
// and SUPABASE_SERVICE_ROLE_KEY are injected automatically; no secrets
// need to be configured for this Phase 1 version.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FPL_URL = "https://fantasy.premierleague.com/api/bootstrap-static/";

const POINTS_WEIGHT = 1.2; // % move per FPL point scored since last sync
const XGI_WEIGHT = 8.0; // % move per unit of expected_goal_involvements gained
const MINUTES_FULL_MATCH_BONUS = 0.3; // % per full match's worth of new minutes (capped at 2 matches)
const HARD_CAP_PCT = 15; // absolute daily cap, both directions
const MIN_MOVE_PCT = 0.05; // ignore noise below this; leave price untouched
const CONCURRENCY = 20; // parallel RPC calls per batch

function num(v: unknown): number {
  const n = typeof v === "string" ? parseFloat(v) : (v as number);
  return Number.isFinite(n) ? n : 0;
}

function injuryDoubtDelta(prevChance: number | null, newChance: number | null): number {
  // FPL's chance_of_playing_next_round: null or 100 = fit; 75/50/25 =
  // doubtful; 0 = ruled out. We only react to it *changing*, not its
  // static value, so a player who's been doubtful for weeks doesn't
  // keep getting penalized every single day.
  const prev = prevChance === null || prevChance === undefined ? 100 : prevChance;
  const next = newChance === null || newChance === undefined ? 100 : newChance;
  if (next < prev) {
    if (next <= 25) return -4;
    if (next <= 50) return -2;
    return -1;
  }
  if (next > prev && next >= 100) {
    return prev <= 50 ? 2 : 1;
  }
  return 0;
}

async function processBatch(supabase: ReturnType<typeof createClient>, jobs: (() => Promise<void>)[]) {
  for (let i = 0; i < jobs.length; i += CONCURRENCY) {
    await Promise.all(jobs.slice(i, i + CONCURRENCY).map((job) => job()));
  }
}

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const fplRes = await fetch(FPL_URL);
  if (!fplRes.ok) {
    return new Response(
      JSON.stringify({ ok: false, reason: `FPL API returned ${fplRes.status}` }),
      { status: 502, headers: { "Content-Type": "application/json" } }
    );
  }
  const fpl = await fplRes.json();
  const elements: any[] = fpl.elements ?? [];

  const { data: existing, error: fetchErr } = await supabase
    .from("players")
    .select("id, fpl_id, minutes, total_points, expected_goal_involvements, chance_of_playing_next_round, current_price")
    .not("fpl_id", "is", null);

  if (fetchErr) {
    return new Response(JSON.stringify({ ok: false, reason: fetchErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const byFplId = new Map((existing ?? []).map((p: any) => [p.fpl_id, p]));
  const errors: string[] = [];
  let matched = 0;
  let priceChanged = 0;

  const jobs: (() => Promise<void>)[] = [];

  for (const el of elements) {
    const row = byFplId.get(el.id);
    if (!row) continue; // not one of our linked players - skip, never insert here
    matched++;

    const prevMinutes = num(row.minutes);
    const prevPoints = num(row.total_points);
    const prevXgi = num(row.expected_goal_involvements);
    const prevChance = row.chance_of_playing_next_round ?? null;

    const newMinutes = num(el.minutes);
    const newPoints = num(el.total_points);
    const newXgi = num(el.expected_goal_involvements);
    const newChance = el.chance_of_playing_next_round ?? null;

    const dPoints = newPoints - prevPoints;
    const dXgi = newXgi - prevXgi;
    const dMinutes = Math.max(newMinutes - prevMinutes, 0);
    const minutesBonus = Math.min(dMinutes / 90, 2) * MINUTES_FULL_MATCH_BONUS;
    const injuryDelta = injuryDoubtDelta(prevChance, newChance);

    let movePct = dPoints * POINTS_WEIGHT + dXgi * XGI_WEIGHT + minutesBonus + injuryDelta;
    movePct = Math.max(-HARD_CAP_PCT, Math.min(HARD_CAP_PCT, movePct));

    let newPrice: number | null = null;
    let reason: string | null = null;
    if (Math.abs(movePct) >= MIN_MOVE_PCT) {
      const currentPrice = num(row.current_price) || 1;
      newPrice = Math.max(1, Math.round(currentPrice * (1 + movePct / 100) * 100) / 100);
      const parts: string[] = [];
      if (dPoints) parts.push(`${dPoints > 0 ? "+" : ""}${dPoints} pts`);
      if (Math.abs(dXgi) >= 0.01) parts.push(`xGI ${dXgi > 0 ? "+" : ""}${dXgi.toFixed(2)}`);
      if (dMinutes > 0) parts.push(`+${dMinutes} min`);
      if (injuryDelta < 0) parts.push("injury doubt");
      if (injuryDelta > 0) parts.push("recovered from doubt");
      reason = `Gameweek sync: ${parts.join(", ") || "minor movement"}`;
      priceChanged++;
    }

    jobs.push(async () => {
      const { error } = await supabase.rpc("apply_player_sync", {
        p_player_id: row.id,
        p_minutes: Math.round(newMinutes),
        p_goals: Math.round(num(el.goals_scored)),
        p_assists: Math.round(num(el.assists)),
        p_total_points: Math.round(newPoints),
        p_form: num(el.form),
        p_ict_index: num(el.ict_index),
        p_expected_goal_involvements: newXgi,
        p_fpl_price: num(el.now_cost) / 10,
        p_chance_of_playing_next_round: newChance,
        p_injury_note: el.news || null,
        p_new_price: newPrice,
        p_reason: reason,
      });
      if (error) errors.push(`fpl_id ${el.id}: ${error.message}`);
    });
  }

  await processBatch(supabase, jobs);

  return new Response(
    JSON.stringify({
      ok: errors.length === 0,
      matched,
      price_changed: priceChanged,
      errors: errors.slice(0, 20),
      error_count: errors.length,
    }),
    { headers: { "Content-Type": "application/json" } }
  );
});
