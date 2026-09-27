// ============================================================================
// raid_manager — Asynchronous Raid Controller (Edge Function, Deno)
// ----------------------------------------------------------------------------
// Thin, stateless orchestrator over two SECURITY DEFINER RPCs so that all
// economy mutations stay atomic inside Postgres:
//
//   POST { action: "begin",   target_boma_id }        -> validates eligibility,
//        escrows milk/energy, returns the defender's 5 slotted Defense Phrases
//        + watchtower time limit for the client decryption minigame.
//
//   POST { action: "resolve", target_boma_id,
//          solved_gates, total_gates, duration_secs } -> grades the attempt.
//          Success (all gates solved in time): transfer 10% of non-quarantined
//          livestock + grant defender a 12h shield. Failure: energy stays
//          burned, defender earns defense trophies.
//
// Anti-cheat notes:
//   * The client never sees the expected token order; grading compares each
//     submitted gate sequence against vocabulary.source_text server-side.
//   * Shield & escrow checks are re-executed inside resolve() via SQL locks.
// ============================================================================

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { CORS_HEADERS, jsonError, preflight } from "../_shared/cors.ts";

const RAID_ENERGY_PER_FENCE = 10; // cost = 10 * defender.fence_level
const SUCCESS_RATIO = 1.0; // attacker must clear every gate

interface BeginAction {
  action: "begin";
  target_boma_id: string;
}
interface ResolveAction {
  action: "resolve";
  target_boma_id: string;
  /** attacker's answer per slot: ordered token list they assembled */
  attempts: Array<{ slot_index: number; tokens: string[] }>;
  duration_secs: number;
}
type RaidAction = BeginAction | ResolveAction;

Deno.serve(async (req: Request) => {
  const corsPreflight = preflight(req);
  if (corsPreflight) return corsPreflight;
  if (req.method !== "POST") return jsonError("method not allowed", 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonError("missing Authorization header", 401);

  let body: RaidAction;
  try {
    body = await req.json();
  } catch {
    return jsonError("invalid JSON body", 400);
  }

  // -- Authenticated client: RLS + auth.uid() resolve to the attacker ---------
  const user: SupabaseClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const {
    data: { user: me },
    error: authErr,
  } = await user.auth.getUser();
  if (authErr || !me) return jsonError("invalid or expired token", 401);

  // =========================================================================
  // ACTION: begin — eligibility gauntlet + defense fetch
  // =========================================================================
  if (body.action === "begin") {
    if (typeof body.target_boma_id !== "string") {
      return jsonError("target_boma_id required", 400);
    }

    // 1. Attacker profile (own row is RLS-visible).
    const { data: attacker, error: aErr } = await user
      .from("player_bomas")
      .select("id, milk_energy, clan_name")
      .eq("user_id", me.id)
      .maybeSingle();
    if (aErr) return jsonError(aErr.message, 500);
    if (!attacker) return jsonError("register a boma before raiding", 403);

    // 2. Target scouting: exists? shielded? affordable? (public read via RLS)
    const { data: target, error: tErr } = await user
      .from("player_bomas")
      .select("id, user_id, clan_name, fence_level, shield_until, boma_tier")
      .eq("id", body.target_boma_id)
      .maybeSingle();
    if (tErr) return jsonError(tErr.message, 500);
    if (!target) return jsonError("target boma not found", 404);
    if (target.user_id === me.id) return jsonError("you cannot raid your own boma", 400);
    if (new Date(target.shield_until) > new Date()) {
      return jsonError("target is under a thorn-shield", 423, {
        code: "TARGET_SHIELDED",
        shield_until: target.shield_until,
      });
    }
    const cost = RAID_ENERGY_PER_FENCE * target.fence_level;
    if (attacker.milk_energy < cost) {
      return jsonError("not enough milk/energy for this assault", 402, {
        code: "INSUFFICIENT_MILK",
        required: cost,
        available: attacker.milk_energy,
      });
    }

    // 3. Escrow energy + fetch verified defense slots atomically in Postgres.
    const { data: config, error: rpcErr } = await user.rpc("begin_raid", {
      p_target_boma_id: body.target_boma_id,
    });
    if (rpcErr) {
      const msg = rpcErr.message ?? "";
      if (msg.includes("TARGET_SHIELDED")) return jsonError("shielded", 423);
      if (msg.includes("INSUFFICIENT_MILK")) return jsonError("insufficient milk", 402);
      return jsonError(msg, 400);
    }

    const cfg = config as {
      raid_cost: number;
      time_limit_secs: number;
      defender_clan: string;
      herd_size: number;
      defense_phrases: Array<{
        slot_index: number;
        phrase_id: string;
        source_text: string;
        translated_text: string;
        audio_url: string | null;
      }>;
    };

    // 4. Build the puzzle server-side: scramble tokens per slot so the client
    //    never has to invent its own shuffle (deterministic replay-safe UX).
    const gates = cfg.defense_phrases.map((p) => ({
      slot_index: p.slot_index,
      phrase_id: p.phrase_id,
      translation_hint: p.translated_text,
      audio_url: p.audio_url,
      // Scrambled pool the player taps into order. Expected order is kept
      // ONLY on the server (recomputed from source_text at resolve time).
      scrambled_tokens: shuffle(p.source_text.split(/\s+/)),
    }));

    return ok({
      status: "engaged",
      defender_clan: cfg.defender_clan,
      herd_size: cfg.herd_size,
      energy_spent: cfg.raid_cost,
      time_limit_secs: cfg.time_limit_secs, // watchtower countdown
      gates,
    });
  }

  // =========================================================================
  // ACTION: resolve — grade gates & settle spoils
  // =========================================================================
  if (body.action === "resolve") {
    if (!Array.isArray(body.attempts)) return jsonError("attempts[] required", 400);

    // Re-fetch the authoritative defense configuration. begin_raid already
    // escrowed energy; here we only need the expected token orders to grade.
    const { data: defs, error: dErr } = await user
      .from("boma_defenses")
      .select("slot_index, phrase_id, vocabulary(source_text)")
      .eq("boma_id", body.target_boma_id);
    if (dErr) return jsonError(dErr.message, 500);
    if (!defs || defs.length === 0) {
      return jsonError("target abandoned its defenses", 404);
    }

    const expected = new Map<number, string[]>(
      defs.map((d: any) => [
        d.slot_index,
        String(d.vocabulary.source_text).trim().split(/\s+/),
      ]),
    );

    // A gate is solved iff the submitted token sequence matches exactly.
    let solvedGates = 0;
    for (const attempt of body.attempts) {
      const want = expected.get(attempt.slot_index);
      if (want && sameSequence(want, attempt.tokens ?? [])) solvedGates++;
    }
    const totalGates = expected.size;
    const success = solvedGates / Math.max(totalGates, 1) >= SUCCESS_RATIO;

    // Settle in Postgres: transfers, 12h shield, trophies, raid_logs insert.
    const { data: result, error: rErr } = await user.rpc("resolve_raid", {
      p_target_boma_id: body.target_boma_id,
      p_success: success,
      p_duration_secs: Math.max(0, Math.floor(body.duration_secs ?? 0)),
    });
    if (rErr) return jsonError(rErr.message, 400);

    const res = result as { success: boolean; livestock_stolen: number };
    return ok({
      status: res.success ? "victory" : "repelled",
      solved_gates: solvedGates,
      total_gates: totalGates,
      livestock_stolen: res.livestock_stolen,
      message: res.success
        ? `You drove ${res.livestock_stolen} head of cattle home.`
        : "The watchman raised the alarm — your herd goes hungry tonight.",
    });
  }

  return jsonError(`unknown action: ${(body as { action: string }).action}`, 400);
});

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function ok(data: unknown): Response {
  return new Response(JSON.stringify(data), { headers: CORS_HEADERS });
}

/** Fisher–Yates shuffle (crypto-strength randomness). */
function shuffle<T>(arr: T[]): T[] {
  const out = [...arr];
  const buf = new Uint32Array(out.length);
  crypto.getRandomValues(buf);
  for (let i = out.length - 1; i > 0; i--) {
    const j = buf[i] % (i + 1);
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

function sameSequence(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  return a.every((tok, i) => tok.toLowerCase() === b[i].toLowerCase());
}
