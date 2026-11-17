// Tests for broker/src/handler.js (spec 0002, M2 step 7b). Offline: GitHub is
// a fake fetch, D1 is an in-memory stub, and the App key is generated here at
// run time. Run with `node --test tests/broker/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  OWNER_ID,
  OTHER_ID,
  OWNER_CRED,
  OTHER_CRED,
  INST_TOKEN,
  OWNER_OTHER_APP,
  LOGIN_SECRET,
  pair,
  d1,
  github,
  env,
  NOW,
  req,
  call,
} from "./helpers.mjs";

function b64urlDecode(s) {
  return Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

test("owner gets a one-repo token signed by the App key", async () => {
  const { res, body, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local" }));
  assert.equal(res.status, 200);
  assert.equal(body.token, INST_TOKEN);
  assert.equal(body.expires_at, "2026-11-16T17:00:00Z");
  assert.equal(res.headers.get("Cache-Control"), "no-store");

  const mint = gh.calls.find((c) => c.url.endsWith("/access_tokens"));
  assert.equal(mint.method, "POST");
  assert.deepEqual(JSON.parse(mint.body), {
    repositories: ["sandbox-node-local"],
    permissions: { contents: "write", pull_requests: "write", issues: "write", checks: "write", metadata: "read" },
  });

  const jwt = mint.auth.replace(/^Bearer /, "");
  const [h, p, s] = jwt.split(".");
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    pair.publicKey,
    b64urlDecode(s),
    new TextEncoder().encode(`${h}.${p}`),
  );
  assert.ok(ok, "JWT verifies with the App's public key");
  const claims = JSON.parse(b64urlDecode(p));
  assert.equal(claims.iss, "5766032");
  assert.equal(claims.iat, NOW / 1000 - 60);
  assert.equal(claims.exp, NOW / 1000 + 540);
});

test("another GitHub user is refused", async () => {
  const { res, body, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local" }, OTHER_CRED));
  assert.equal(res.status, 403);
  assert.equal(body.error, "not_owner");
  assert.ok(!gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
});

test("no token and a bad token are refused", async () => {
  let r = await call(req({ repo: "Jomaries777/sandbox-node-local" }, null));
  assert.equal(r.res.status, 401);
  assert.equal(r.body.error, "no_token");
  assert.equal(r.gh.calls.length, 0, "no GitHub call without a token");
  r = await call(req({ repo: "Jomaries777/sandbox-node-local" }, "nonsense"));
  assert.equal(r.res.status, 401);
  assert.equal(r.body.error, "bad_token");
});

test("an owner token the login App did not issue is refused", async () => {
  const { res, body, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local" }, OWNER_OTHER_APP));
  assert.equal(res.status, 401);
  assert.equal(body.error, "bad_token");
  assert.ok(!gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
});

test("the token check uses the login App's client credentials", async () => {
  const { res } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), env({ LOGIN_CLIENT_SECRET: "wrong-secret-x" }));
  assert.equal(res.status, 401, "a wrong client secret identifies nobody");
});

test("repo names are validated before the repo is looked up", async () => {
  for (const repo of ["Jomaries777/..", "Jomaries777/.", "sandbox-node-local", "a/b/c", "", "Jomaries777/" + "x".repeat(101), "Jomaries777/a b", 42, null]) {
    const { res, body, gh } = await call(req({ repo }));
    assert.equal(res.status, 400, `repo ${JSON.stringify(repo)}`);
    assert.equal(body.error, "bad_repo");
    assert.ok(!gh.calls.some((c) => c.url.includes("/repos/")), "no repo call for a bad name");
  }
  const bad = await call(req(null, OWNER_CRED, { raw: "{not json" }));
  assert.equal(bad.res.status, 400);
  assert.equal(bad.body.error, "bad_json");
});

test("a repo of another owner is refused, never mapped to the owner's", async () => {
  const { res, body, gh } = await call(req({ repo: "other-org/sandbox-node-local" }));
  assert.equal(res.status, 400);
  assert.equal(body.error, "wrong_owner");
  assert.ok(!gh.calls.some((c) => c.url.includes("/repos/")), "no repo lookup");
  const ok = await call(req({ repo: "jomaries777/sandbox-node-local" }));
  assert.equal(ok.res.status, 200, "the owner's login is matched without case");
});

test("refused requests count toward the hourly limit too", async () => {
  const e = env();
  for (let i = 0; i < 30; i++) {
    const { res } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e, github({ installStatus: 404 }));
    assert.equal(res.status, 404);
  }
  const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
  assert.equal(res.status, 429);
  assert.equal(body.error, "rate_limited");
});

test("throttled requests write no audit rows", async () => {
  const e = env();
  for (let i = 0; i < 30; i++) await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
  for (let i = 0; i < 5; i++) {
    const { res } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
    assert.equal(res.status, 429);
  }
  assert.equal(e.AUDIT.rows.length, 30, "only the 30 answered requests are stored");
});

test("another GitHub user gets one audited refusal an hour, then no writes", async () => {
  const e = env();
  const first = await call(req({ repo: "Jomaries777/sandbox-node-local" }, OTHER_CRED), e);
  assert.equal(first.res.status, 403);
  for (let i = 0; i < 10; i++) {
    const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local" }, OTHER_CRED), e);
    assert.equal(res.status, 429);
    assert.equal(body.error, "rate_limited");
  }
  assert.equal(e.AUDIT.rows.length, 1);
  const owner = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
  assert.equal(owner.res.status, 200, "the owner is not limited by others");
});

test("without a working audit database nothing is issued", async () => {
  let r = await call(req({ repo: "Jomaries777/sandbox-node-local" }), env({ AUDIT: undefined }));
  assert.equal(r.res.status, 503);
  assert.equal(r.body.error, "audit_unavailable");
  assert.equal(r.gh.calls.length, 0, "refused before any GitHub call");
  const broken = d1({ failRead: true });
  r = await call(req({ repo: "Jomaries777/sandbox-node-local" }), env({ AUDIT: broken }));
  assert.equal(r.res.status, 503);
  assert.equal(r.body.error, "audit_unavailable");
  assert.ok(!r.gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
  assert.equal(broken.rows.length, 0);
});

test("a body over 1 KB is refused", async () => {
  const { res, body } = await call(req(null, OWNER_CRED, { raw: JSON.stringify({ repo: "x", pad: "y".repeat(2000) }) }));
  assert.equal(res.status, 413);
  assert.equal(body.error, "too_large");
});

test("a streamed body over 1 KB is refused without reading it all", async () => {
  const { res, body } = await call(req(null, OWNER_CRED, { stream: 100 }));
  assert.equal(res.status, 413);
  assert.equal(body.error, "too_large");
});

test("the kill switch refuses everything", async () => {
  const { res, body, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), env({ BROKER_ENABLED: "false" }));
  assert.equal(res.status, 503);
  assert.equal(body.error, "disabled");
  assert.equal(gh.calls.length, 0);
});

test("a repo without the bot installed is 404", async () => {
  const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), env(), github({ installStatus: 404 }));
  assert.equal(res.status, 404);
  assert.equal(body.error, "not_installed");
});

test("GitHub failures become 502", async () => {
  const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), env(), github({ tokenStatus: 500 }));
  assert.equal(res.status, 502);
  assert.equal(body.error, "github_error");
});

test("the 31st token in an hour is rate limited", async () => {
  const e = env();
  for (let i = 0; i < 30; i++) {
    const { res } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
    assert.equal(res.status, 200);
  }
  const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
  assert.equal(res.status, 429);
  assert.equal(body.error, "rate_limited");
});

test("identified callers are audited, anonymous refusals are not, and no token is stored", async () => {
  const e = env();
  await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local" }, OTHER_CRED), e);
  await call(req({ repo: "Jomaries777/.." }), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local" }, null), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local" }, "nonsense"), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local" }, OWNER_OTHER_APP), e);
  const rows = e.AUDIT.rows;
  assert.equal(rows.length, 3, "no, bad and foreign tokens leave no row");
  assert.deepEqual(
    rows.map((r) => [r.outcome, r.reason, r.caller_id]),
    [
      ["issued", null, OWNER_ID],
      ["refused", "not_owner", OTHER_ID],
      ["refused", "bad_repo", OWNER_ID],
    ],
  );
  assert.equal(rows[0].ip, "203.0.113.9");
  const stored = JSON.stringify(rows);
  for (const secret of [OWNER_CRED, OTHER_CRED, INST_TOKEN, LOGIN_SECRET]) {
    assert.ok(!stored.includes(secret), "audit holds no token");
  }
});

test("old audit rows are deleted now and then, not on every write", async () => {
  const e = env();
  e.AUDIT.rows.push({ ts: NOW - 91 * 24 * 3600 * 1000, caller_id: "1", endpoint: "token", outcome: "issued" });
  await call(req({ repo: "Jomaries777/sandbox-node-local" }), e, github(), () => 0.5);
  assert.equal(e.AUDIT.rows.length, 2, "kept when this write doesn't prune");
  await call(req({ repo: "Jomaries777/sandbox-node-local" }), e, github(), () => 0);
  assert.equal(e.AUDIT.rows.length, 2, "the 91-day-old row is gone, two new rows remain");
  assert.ok(e.AUDIT.rows.every((r) => r.ts === NOW));
});

test("healthz, unknown paths and wrong methods", async () => {
  let r = await call(req(null, null, { path: "/healthz", method: "GET" }));
  assert.equal(r.res.status, 200);
  assert.deepEqual(r.body, { ok: true, enabled: true });
  r = await call(req(null, null, { path: "/nope", method: "GET" }));
  assert.equal(r.res.status, 404);
  r = await call(req(null, OWNER_CRED, { path: "/token", method: "GET" }));
  assert.equal(r.res.status, 405);
});
