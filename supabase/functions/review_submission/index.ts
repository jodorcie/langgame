// ============================================================================
// review_submission  —  The "Council of Elders" consensus engine.
// ----------------------------------------------------------------------------
// Invoked by a reviewer's client after they swipe on a pending phrase.
// Runs with the caller's JWT for identity, then uses a service-role client
// (bypasses RLS) for the privileged transitions:
//
//   1. Upsert the reviewer's verdict into `phrase_validations`
//      (unique on (phrase_id, reviewer_id) => re-swiping updates the vote).
//   2. Recompute consensus from the validation ledger.
//   3. If approvals >= CONSENSUS_MIN_APPROVALS (3) AND approval ratio >= 75%:
//        • vocabulary.status -> 'verified' (+ synced upvotes/downvotes)
//        • Mint a calf into the CONTRIBUTOR's herd with SM-2 defaults:
//              interval_days = 1, ease_factor = 2.5, next_review_at = NOW()+1d
//        • Award the REVIEWER reputation points + a defensive shield token.
// ============================================================================

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { CORS_HEADERS, jsonError, preflight } from "../_shared/cors.ts";

// ---- Tunable consensus parameters -----------------------------------------
const CONSENSUS_MIN_APPROVALS = 3; // absolute floor of positive elders
const CONSENSUS_APPROVAL_RATIO = 0.75; // >= 75% of validators agree
const REVIEWER_REPUTATION_POINTS = 10; // per validated submission decision
const SHIELD_ITEM_ID = "shield_thorn_branch"; // inventory item key

interface ReviewPayload {
  phrase_id: string;
  is_accurate: boolean;
  notes?: string | null;
}

interface VocabularyRow {
  id: string;
  contributor_id: string;
  status: string;
  language_code: string;
  category: string;
}

Deno.serve(async (req: Request) => {
  // 1. Transport plumbing ------------------------------------------------------
  const corsPreflight = preflight(req);
  if (corsPreflight) return corsPreflight;
  if (req.method !== "POST") return jsonError("method not allowed", 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return jsonError("missing Authorization header", 401);

  let payload: ReviewPayload;
  try {
    payload = await req.json();
  } catch {
    return jsonError("invalid JSON body", 400);
  }
  const { phrase_id, is_accurate } = payload ?? ({} as ReviewPayload);
  if (typeof phrase_id !== "string" || typeof is_accurate !== "boolean") {
    return jsonError("expected { phrase_id: string, is_accurate: boolean }", 400);
  }

  // 2. Clients -----------------------------------------------------------------
  // Anon client carrying the user JWT -> auth.uid() resolves to the reviewer.
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const {
    data: { user },
    error: userErr,
  } = await userClient.auth.getUser();
  if (userErr || !user) return jsonError("invalid or expired token", 401);
  const reviewerId = user.id;

  // Service-role client for privileged writes (RLLS bypass).
  const admin: SupabaseClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 3. Load & guard the target phrase -------------------------------------------
  const { data: phrase, error: phraseErr } = await admin
    .from("vocabulary")
    .select("id, contributor_id, status, language_code, category")
    .eq("id", phrase_id)
    .maybeSingle<VocabularyRow>();

  if (phraseErr) return jsonError(phraseErr.message, 500);
  if (!phrase) return jsonError("phrase not found", 404);
  if (phrase.contributor_id === reviewerId) {
    return jsonError("elders cannot review their own submissions", 403);
  }
  if (phrase.status !== "pending") {
    // Idempotency guard: already adjudicated — report current state, no-op.
    return new Response(
      JSON.stringify({ verified: false, already_decided: true, status: phrase.status }),
      { headers: CORS_HEADERS },
    );
  }

  // 4. Record the verdict (UPSERT on (phrase_id, reviewer_id)) -------------------
  const { error: insertErr } = await admin.from("phrase_validations").upsert(
    {
      phrase_id,
      reviewer_id: reviewerId,
      is_accurate,
      notes: payload.notes ?? null,
      created_at: new Date().toISOString(),
    },
    { onConflict: "phrase_id,reviewer_id" },
  );
  if (insertErr) return jsonError(insertErr.message, 500);

  // 5. Recompute consensus from the authoritative ledger --------------------------
  const { count: approvals, error: appErr } = await admin
    .from("phrase_validations")
    .select("*", { count: "exact", head: true })
    .eq("phrase_id", phrase_id)
    .eq("is_accurate", true);
  const { count: rejections, error: rejErr } = await admin
    .from("phrase_validations")
    .select("*", { count: "exact", head: true })
    .eq("phrase_id", phrase_id)
    .eq("is_accurate", false);
  if (appErr || rejErr) return jsonError((appErr ?? rejErr)!.message, 500);

  const yes = approvals ?? 0;
  const no = rejections ?? 0;
  const total = yes + no;
  const ratio = total > 0 ? yes / total : 0;
  const reachedConsensus = yes >= CONSENSUS_MIN_APPROVALS && ratio >= CONSENSUS_APPROVAL_RATIO;

  // Sync denormalized vote counters so leaderboards/queues don't re-count.
  await admin
    .from("vocabulary")
    .update({ upvotes: yes, downvotes: no, updated_at: new Date().toISOString() })
    .eq("id", phrase_id);

  if (!reachedConsensus) {
    return new Response(
      JSON.stringify({
        verified: false,
        consensus: { approvals: yes, rejections: no, ratio },
      }),
      { headers: CORS_HEADERS },
    );
  }

  // 6a. Verify the phrase -----------------------------------------------------------
  const { error: verifyErr } = await admin
    .from("vocabulary")
    .update({ status: "verified", updated_at: new Date().toISOString() })
    .eq("id", phrase_id)
    .eq("status", "pending"); // optimistic lock: only transition once
  if (verifyErr) return jsonError(verifyErr.message, 500);
  if (verifyErr === null) {
    // If 0 rows changed, another concurrent review already verified it.
    const { data: fresh } = await admin
      .from("vocabulary")
      .select("id")
      .eq("id", phrase_id)
      .eq("status", "verified")
      .maybeSingle();
    if (!fresh) {
      return new Response(JSON.stringify({ verified: false, raced: true }), {
        headers: CORS_HEADERS,
      });
    }
  }

  // 6b. Hatch a calf in the contributor's boma (SM-2 birth defaults) ----------------
  const { data: contributorBoma, error: bomaErr } = await admin
    .from("player_bomas")
    .select("id")
    .eq("user_id", phrase.contributor_id)
    .maybeSingle<{ id: string }>();
  if (bomaErr) return jsonError(bomaErr.message, 500);

  let mintedAnimalId: string | null = null;
  if (contributorBoma) {
    const tomorrow = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    // Species flavored by category: idioms graze as goats, tools as bulls, etc.
    const species =
      phrase.category === "livestock" ? "cow"
      : phrase.category === "idioms" || phrase.category === "kinship" ? "goat"
      : phrase.category === "tools" ? "bull"
      : "calf";

    const { data: animal, error: animalErr } = await admin
      .from("herd_animals")
      .insert({
        boma_id: contributorBoma.id,
        phrase_id,
        animal_type: species,
        health_status: "healthy",
        interval_days: 1.0, // SM-2 initial interval
        ease_factor: 2.5, // SM-2 initial EF
        repetition_count: 0,
        next_review_at: tomorrow, // NOW() + 1 day
      })
      .select("id")
      .single();
    if (animalErr && animalErr.code !== "23505") {
      // 23505 = unique(uq_herd_phrase) => calf already minted; treat as success.
      return jsonError(animalErr.message, 500);
    }
    mintedAnimalId = animal?.id ?? null;
  }

  // 6c. Reward the reviewer: reputation + one shield item ----------------------------
  const { data: reviewerBoma, error: rbErr } = await admin
    .from("player_bomas")
    .select("id, reputation")
    .eq("user_id", reviewerId)
    .maybeSingle<{ id: string; reputation: number }>();
  if (!rbErr && reviewerBoma) {
    await admin
      .from("player_bomas")
      .update({
        reputation: reviewerBoma.reputation + REVIEWER_REPUTATION_POINTS,
        updated_at: new Date().toISOString(),
      })
      .eq("id", reviewerBoma.id);

    // Grant a single-use shield token (extends shield_until when consumed in-app).
    await admin.from("player_inventory").upsert(
      { boma_id: reviewerBoma.id, item_id: SHIELD_ITEM_ID },
      { onConflict: "boma_id,item_id", ignoreDuplicate: false },
    ).then(({ error }) => {
      // Inventory table is optional at MVP; swallow its absence silently.
      if (error && error.code !== "42P01") console.error("inventory grant:", error.message);
    });
  }

  // 7. Success envelope ---------------------------------------------------------------
  return new Response(
    JSON.stringify({
      verified: true,
      consensus: { approvals: yes, rejections: no, ratio },
      minted_animal_id: mintedAnimalId,
      reviewer_reward: {
        reputation: REVIEWER_REPUTATION_POINTS,
        shield_item: SHIELD_ITEM_ID,
      },
    }),
    { headers: CORS_HEADERS },
  );
});
