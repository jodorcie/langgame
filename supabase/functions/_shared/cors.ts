// Shared CORS helpers for all Boma Edge Functions (Deno / Supabase runtime).
export const CORS_HEADERS: Record<string, string> = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS, GET",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

/** Respond to pre-flight requests immediately. */
export function preflight(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  return null;
}

/** Uniform JSON error envelope. */
export function jsonError(
  message: string,
  code = 400,
  extra: Record<string, unknown> = {},
): Response {
  return new Response(
    JSON.stringify({ error: message, ...extra }),
    { status: code, headers: CORS_HEADERS },
  );
}
