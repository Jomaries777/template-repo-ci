// Bot token broker (spec 0002, phase 2). A caller proves it is the owner with
// a user token of the login-only GitHub App (no permissions). The broker
// checks that token with GitHub's "Check a token" endpoint, which confirms it
// was issued by that App and names the user, then answers with a 1-hour
// installation token of the bot App, limited to one repo. Any other token of
// the owner's (gh CLI, a PAT, another OAuth app) is refused. The App key never
// leaves this Worker. Requests from identified callers are audited without
// tokens; anonymous and throttled refusals are not stored, so nobody can fill
// the database. Without a working audit database the broker refuses.
// Dependencies are injected so tests run offline:
//   handle(request, env, { fetch, now, random })   now() returns milliseconds.

import { appJwt } from "./jwt.js";
import { gh } from "./github.js";
import { relay, RELAY_MAX_BODY } from "./relay.js";
import { secrets } from "./secrets.js";

const MAX_BODY = 1024; // bytes, /token
// "owner/name"; the owner must be OWNER_LOGIN, so a token is never minted for
// a same-named repo of another owner.
const REPO_RE = /^([A-Za-z0-9-]{1,39})\/([A-Za-z0-9._-]{1,100})$/;
// Every request of an identified caller counts, refused ones included, so
// repeated failures that reach GitHub are limited too. A guard, not a hard
// limit: the count is read before the row is written, so concurrent requests
// can pass it together. Enough for one owner's devices. Any GitHub user can
// sign in to the login App, so a non-owner gets one audited refusal an hour;
// throttled requests write nothing, so no caller can fill the database.
const RATE_PER_HOUR = { token: 30, relay: 20, secrets: 10 };
const NON_OWNER_PER_HOUR = 1;
const RETENTION_MS = 90 * 24 * 3600 * 1000;
// Old rows are deleted on about 1 write in 50, not every write (CPU, C7).
const PRUNE_CHANCE = 0.02;
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

async function audit(env, row, nowMs, random) {
  if (!env.AUDIT) return;
  try {
    await env.AUDIT.prepare(
      "INSERT INTO audit (ts, caller_id, endpoint, repo, outcome, reason, expires_at, ip, branch, files, paths) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
      .bind(
        nowMs,
        row.caller_id,
        row.endpoint,
        row.repo,
        row.outcome,
        row.reason,
        row.expires_at,
        row.ip,
        row.branch ?? null,
        row.files ?? null,
        row.paths ?? null,
      )
      .run();
    if (random() < PRUNE_CHANCE) {
      await env.AUDIT.prepare("DELETE FROM audit WHERE ts < ?").bind(nowMs - RETENTION_MS).run();
    }
  } catch {
    // The answer still goes out; never log row contents.
    console.error("audit write failed");
  }
}

// requestsLastHour: the caller's audited requests in the last hour. Throws if
// D1 fails; the caller then refuses (fail closed), since the limit needs it.
// schemaOk: the audit table has every column the INSERT names. Checked once
// per isolate, so deploying before a migration refuses requests instead of
// answering them without an audit row or a rate limit.
let schemaChecked = false;
async function schemaOk(env) {
  if (schemaChecked) return true;
  try {
    await env.AUDIT.prepare("SELECT ts, caller_id, endpoint, repo, outcome, reason, expires_at, ip, branch, files, paths FROM audit LIMIT 0").all();
    schemaChecked = true;
    return true;
  } catch {
    console.error("audit schema check failed: run the migrations");
    return false;
  }
}
// For tests: forget the cached check.
export function resetSchemaCheck() {
  schemaChecked = false;
}

async function requestsLastHour(env, callerId, endpoint, nowMs) {
  const r = await env.AUDIT.prepare(
    "SELECT COUNT(*) AS n FROM audit WHERE caller_id = ? AND endpoint = ? AND ts > ?",
  )
    .bind(callerId, endpoint, nowMs - 3600 * 1000)
    .first();
  return Number(r?.n ?? 0);
}

// readJson: parse a JSON object body of at most MAX_BODY bytes, reading no
// more than that from the stream.
export async function readJson(request, max = MAX_BODY) {
  // A declared length is checked first; a body without one (chunked) is
  // capped by the stream loop below.
  const len = Number(request.headers.get("Content-Length") || "0");
  if (len > max) return { error: [413, "too_large"] };
  const chunks = [];
  let size = 0;
  if (request.body) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > max) {
        await reader.cancel();
        return { error: [413, "too_large"] };
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  try {
    const v = JSON.parse(new TextDecoder().decode(bytes));
    if (v === null || typeof v !== "object" || Array.isArray(v)) return { error: [400, "bad_json"] };
    return { value: v };
  } catch {
    return { error: [400, "bad_json"] };
  }
}

// whoIs: the GitHub user ID behind a login-App token, or null. "Check a token"
// answers 200 only for tokens that App issued; it needs the App's client
// credentials, which only this Worker holds.
async function whoIs(env, deps, userToken) {
  const basic = btoa(`${env.LOGIN_CLIENT_ID}:${env.LOGIN_CLIENT_SECRET}`);
  const r = await gh(deps.fetch, `/applications/${env.LOGIN_CLIENT_ID}/token`, {
    auth: `Basic ${basic}`,
    method: "POST",
    body: { access_token: userToken },
  });
  if (r.status !== 200 || r.data?.user?.id === undefined) return null;
  return String(r.data.user.id);
}

// identify: who is calling, before anything else is read or stored. Returns
// { callerId } or { error: [status, body] }. Sets row.caller_id once the
// request will be audited (not for throttled callers).
async function identify(request, env, deps, row, endpoint, nowMs) {
  if (env.BROKER_ENABLED !== "true") return { error: [503, { error: "disabled" }] };
  // Without the audit database there is no log and no rate limit: refuse.
  if (!env.AUDIT || !(await schemaOk(env))) return { error: [503, { error: "audit_unavailable" }] };
  const callerToken = bearer(request);
  if (!callerToken) return { error: [401, { error: "no_token" }] };
  const callerId = await whoIs(env, deps, callerToken);
  if (!callerId) return { error: [401, { error: "bad_token" }] };
  const isOwner = callerId === String(env.OWNER_ID);
  let used;
  try {
    used = await requestsLastHour(env, callerId, endpoint, nowMs);
  } catch {
    console.error("audit read failed");
    return { error: [503, { error: "audit_unavailable" }] };
  }
  if (used >= (isOwner ? RATE_PER_HOUR[endpoint] : NON_OWNER_PER_HOUR)) {
    return { error: [429, { error: "rate_limited" }] };
  }
  // From here on every answer is audited.
  row.caller_id = callerId;
  if (!isOwner) return { error: [403, { error: "not_owner" }] };
  return { callerId };
}

// checkRepo: "owner/name" of the configured owner. Returns { name } or
// { error }. Sets row.repo once the name is well formed.
export function checkRepo(env, full, row) {
  const m = typeof full === "string" ? REPO_RE.exec(full) : null;
  if (!m || m[2] === "." || m[2] === "..") return { error: [400, { error: "bad_repo" }] };
  row.repo = full;
  if (m[1].toLowerCase() !== String(env.OWNER_LOGIN).toLowerCase()) {
    return { error: [400, { error: "wrong_owner" }] };
  }
  return { name: m[2] };
}

// mintToken: a 1-hour installation token of the bot App for one repo.
// Returns { token, expires_at } or { error }.
export async function mintToken(env, deps, repo, nowMs) {
  const jwt = await appJwt(env.APP_ID, env.APP_KEY_PKCS8, Math.floor(nowMs / 1000));
  const inst = await gh(deps.fetch, `/repos/${env.OWNER_LOGIN}/${repo}/installation`, {
    auth: `Bearer ${jwt}`,
  });
  if (inst.status === 404) return { error: [404, { error: "not_installed" }] };
  if (inst.status !== 200 || !inst.data?.id) return { error: [502, { error: "github_error" }] };
  const tok = await gh(deps.fetch, `/app/installations/${inst.data.id}/access_tokens`, {
    auth: `Bearer ${jwt}`,
    method: "POST",
    body: { repositories: [repo], permissions: PERMISSIONS },
  });
  if (tok.status !== 201 || !tok.data?.token) return { error: [502, { error: "github_error" }] };
  return { token: tok.data.token, expires_at: tok.data.expires_at ?? null };
}

async function token(request, env, deps, row) {
  const nowMs = deps.now();
  const who = await identify(request, env, deps, row, "token", nowMs);
  if (who.error) return who.error;

  const body = await readJson(request);
  if (body.error) return [body.error[0], { error: body.error[1] }];
  const repo = checkRepo(env, body.value.repo, row);
  if (repo.error) return repo.error;

  const minted = await mintToken(env, deps, repo.name, nowMs);
  if (minted.error) return minted.error;
  row.expires_at = minted.expires_at;
  return [200, { token: minted.token, expires_at: minted.expires_at }];
}

async function relayRoute(request, env, deps, row) {
  const nowMs = deps.now();
  const who = await identify(request, env, deps, row, "relay", nowMs);
  if (who.error) return who.error;
  const body = await readJson(request, RELAY_MAX_BODY);
  if (body.error) return [body.error[0], { error: body.error[1] }];
  return relay(env, deps, body.value, row, nowMs, { checkRepo, mintToken });
}

async function secretsRoute(request, env, deps, row) {
  const nowMs = deps.now();
  const who = await identify(request, env, deps, row, "secrets", nowMs);
  if (who.error) return who.error;
  const body = await readJson(request);
  if (body.error) return [body.error[0], { error: body.error[1] }];
  return secrets(env, deps, body.value, row, request, { checkRepo });
}

export async function handle(request, env, deps) {
  const random = deps.random ?? Math.random;
  const url = new URL(request.url);
  if (url.pathname === "/healthz") {
    if (request.method !== "GET") return json(405, { error: "method_not_allowed" });
    return json(200, { ok: true, enabled: env.BROKER_ENABLED === "true" });
  }
  // "/relay/" too: a cloud environment's network secret limited to the path
  // prefix /relay is only attached under /relay/. Exact aliases only:
  // "/relay//" or "/relay/x" stay 404 on purpose.
  const routes = { "/token": token, "/relay": relayRoute, "/relay/": relayRoute, "/secrets": secretsRoute };
  const route = routes[url.pathname];
  if (!route) return json(404, { error: "not_found" });
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const row = {
    caller_id: null,
    endpoint: url.pathname.replace(/^\/|\/$/g, ""),
    repo: null,
    outcome: "refused",
    reason: null,
    expires_at: null,
    ip: request.headers.get("CF-Connecting-IP"),
  };
  let status = 500;
  let out = { error: "internal" };
  try {
    [status, out] = await route(request, env, deps, row);
  } catch {
    status = 502;
    out = { error: "github_error" };
  } finally {
    row.outcome = status === 200 ? "issued" : "refused";
    row.reason = status === 200 ? null : out.error;
    // Anonymous refusals (no or invalid token, kill switch), throttled
    // requests and audit failures are not stored.
    if (row.caller_id) await audit(env, row, deps.now(), random);
  }
  return json(status, out);
}
