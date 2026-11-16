// Bot token broker (spec 0002, phase 2). A caller proves it is the owner with
// a GitHub token from the login-only App (no permissions); the broker answers
// with a 1-hour installation token of the bot App, limited to one repo.
// The App key never leaves this Worker. Every request is audited without
// tokens. Dependencies are injected so tests run offline:
//   handle(request, env, { fetch, now })   now() returns milliseconds.

import { appJwt } from "./jwt.js";
import { gh } from "./github.js";

const MAX_BODY = 1024;
const REPO_RE = /^[A-Za-z0-9._-]{1,100}$/;
const RATE_PER_HOUR = 30;
const RETENTION_MS = 90 * 24 * 3600 * 1000;
// The bot App's own permissions; GitHub refuses anything wider.
const PERMISSIONS = {
  contents: "write",
  pull_requests: "write",
  issues: "write",
  checks: "write",
  metadata: "read",
};

function json(status, obj) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function bearer(request) {
  const h = request.headers.get("Authorization") || "";
  const m = /^Bearer\s+(\S+)$/i.exec(h);
  return m ? m[1] : null;
}

async function audit(env, row, nowMs) {
  if (!env.AUDIT) return;
  try {
    await env.AUDIT.prepare(
      "INSERT INTO audit (ts, caller_id, endpoint, repo, outcome, reason, expires_at, ip) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    )
      .bind(nowMs, row.caller_id, row.endpoint, row.repo, row.outcome, row.reason, row.expires_at, row.ip)
      .run();
    await env.AUDIT.prepare("DELETE FROM audit WHERE ts < ?").bind(nowMs - RETENTION_MS).run();
  } catch {
    // The answer still goes out; never log row contents.
    console.error("audit write failed");
  }
}

async function issuedLastHour(env, callerId, nowMs) {
  if (!env.AUDIT) return 0;
  const r = await env.AUDIT.prepare(
    "SELECT COUNT(*) AS n FROM audit WHERE caller_id = ? AND endpoint = 'token' AND outcome = 'issued' AND ts > ?",
  )
    .bind(callerId, nowMs - 3600 * 1000)
    .first();
  return Number(r?.n ?? 0);
}

async function readJson(request) {
  const len = Number(request.headers.get("Content-Length") || "0");
  if (len > MAX_BODY) return { error: [413, "too_large"] };
  const text = await request.text();
  if (text.length > MAX_BODY) return { error: [413, "too_large"] };
  try {
    const v = JSON.parse(text);
    if (v === null || typeof v !== "object" || Array.isArray(v)) return { error: [400, "bad_json"] };
    return { value: v };
  } catch {
    return { error: [400, "bad_json"] };
  }
}

async function token(request, env, deps, row) {
  const nowMs = deps.now();
  if (env.BROKER_ENABLED !== "true") return [503, { error: "disabled" }];

  const body = await readJson(request);
  if (body.error) return [body.error[0], { error: body.error[1] }];
  const repo = body.value.repo;
  if (typeof repo !== "string" || !REPO_RE.test(repo) || repo === "." || repo === "..") {
    return [400, { error: "bad_repo" }];
  }
  row.repo = repo;

  const callerToken = bearer(request);
  if (!callerToken) return [401, { error: "no_token" }];
  const me = await gh(deps.fetch, "/user", { auth: `Bearer ${callerToken}` });
  if (me.status !== 200 || !me.data || me.data.id === undefined) return [401, { error: "bad_token" }];
  row.caller_id = String(me.data.id);
  if (String(me.data.id) !== String(env.OWNER_ID)) return [403, { error: "not_owner" }];

  if ((await issuedLastHour(env, row.caller_id, nowMs)) >= RATE_PER_HOUR) {
    return [429, { error: "rate_limited" }];
  }

  const jwt = await appJwt(env.APP_ID, env.APP_KEY_PKCS8, Math.floor(nowMs / 1000));
  const inst = await gh(deps.fetch, `/repos/${env.OWNER_LOGIN}/${repo}/installation`, {
    auth: `Bearer ${jwt}`,
  });
  if (inst.status === 404) return [404, { error: "not_installed" }];
  if (inst.status !== 200 || !inst.data?.id) return [502, { error: "github_error" }];

  const tok = await gh(deps.fetch, `/app/installations/${inst.data.id}/access_tokens`, {
    auth: `Bearer ${jwt}`,
    method: "POST",
    body: { repositories: [repo], permissions: PERMISSIONS },
  });
  if (tok.status !== 201 || !tok.data?.token) return [502, { error: "github_error" }];
  row.expires_at = tok.data.expires_at ?? null;
  return [200, { token: tok.data.token, expires_at: tok.data.expires_at }];
}

export async function handle(request, env, deps) {
  const url = new URL(request.url);
  if (url.pathname === "/healthz") {
    if (request.method !== "GET") return json(405, { error: "method_not_allowed" });
    return json(200, { ok: true, enabled: env.BROKER_ENABLED === "true" });
  }
  if (url.pathname !== "/token") return json(404, { error: "not_found" });
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const row = {
    caller_id: null,
    endpoint: "token",
    repo: null,
    outcome: "refused",
    reason: null,
    expires_at: null,
    ip: request.headers.get("CF-Connecting-IP"),
  };
  let status = 500;
  let out = { error: "internal" };
  try {
    [status, out] = await token(request, env, deps, row);
  } catch {
    status = 502;
    out = { error: "github_error" };
  } finally {
    row.outcome = status === 200 ? "issued" : "refused";
    row.reason = status === 200 ? null : out.error;
    await audit(env, row, deps.now());
  }
  return json(status, out);
}
