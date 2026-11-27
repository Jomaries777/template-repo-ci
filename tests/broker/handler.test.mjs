// Tests for broker/src/handler.js (spec 0002, spec 0003 FR-2 & NFR-5).
// Offline: GitHub is a fake fetch, D1 is an in-memory stub, and the App keys
// are generated here at run time. Run with `node --test tests/broker/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mintToken } from "../../broker/src/handler.js";
import {
  OWNER_ID,
  OTHER_ID,
  OWNER_CRED,
  OTHER_CRED,
  INST_TOKEN,
  OWNER_OTHER_APP,
  LOGIN_SECRET,
  CLAUDE_APP_ID,
  CLAUDE_APP_SLUG,
  CLAUDE_BOT_ID,
  AGY_APP_ID,
  AGY_APP_SLUG,
  AGY_BOT_ID,
  claudePair,
  agyPair,
  ciPair,
  claudePem,
  agyPem,
  ciPem,
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

async function verifyJwt(jwt, publicKey) {
  const [h, p, s] = jwt.split(".");
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    publicKey,
    b64urlDecode(s),
    new TextEncoder().encode(`${h}.${p}`),
  );
  return { ok, claims: JSON.parse(b64urlDecode(p)) };
}

test("owner gets a one-repo claude token with login, id and audit agent", async () => {
  const { res, body, e, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }));
  assert.equal(res.status, 200);
  assert.deepEqual(body, {
    token: INST_TOKEN,
    expires_at: "2026-11-16T17:00:00Z",
    login: `${CLAUDE_APP_SLUG}[bot]`,
    id: CLAUDE_BOT_ID,
  });
  assert.equal(typeof body.id, "number");
  assert.equal(res.headers.get("Cache-Control"), "no-store");

  const mint = gh.calls.find((c) => c.url.endsWith("/access_tokens"));
  assert.equal(mint.method, "POST");
  assert.deepEqual(JSON.parse(mint.body), {
    repositories: ["sandbox-node-local"],
    permissions: {
      contents: "write",
      pull_requests: "write",
      issues: "write",
      checks: "write",
      actions: "read",
      metadata: "read",
    },
  });

  const jwt = mint.auth.replace(/^Bearer /, "");
  const v = await verifyJwt(jwt, claudePair.publicKey);
  assert.ok(v.ok, "JWT verifies with the claude App's public key");
  assert.ok(!(await verifyJwt(jwt, agyPair.publicKey)).ok, "JWT does not verify with agy key");
  assert.ok(!(await verifyJwt(jwt, ciPair.publicKey)).ok, "JWT does not verify with ci key");
  assert.equal(v.claims.iss, CLAUDE_APP_ID);
  assert.equal(v.claims.iat, NOW / 1000 - 60);
  assert.equal(v.claims.exp, NOW / 1000 + 540);

  const userCall = gh.calls.find((c) => c.url === `https://api.github.com/users/${CLAUDE_APP_SLUG}%5Bbot%5D`);
  assert.ok(userCall, "looks up bot user ID via /users/<slug>%5Bbot%5D");
  assert.equal(userCall.method, "GET");

  const row = e.AUDIT.rows.at(-1);
  assert.equal(row.agent, "claude");
  assert.equal(row.endpoint, "token");
  assert.equal(row.outcome, "issued");
});

test("owner gets a one-repo agy token signed by the agy App key", async () => {
  const { res, body, e, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "agy" }));
  assert.equal(res.status, 200);
  assert.deepEqual(body, {
    token: INST_TOKEN,
    expires_at: "2026-11-16T17:00:00Z",
    login: `${AGY_APP_SLUG}[bot]`,
    id: AGY_BOT_ID,
  });

  const mint = gh.calls.find((c) => c.url.endsWith("/access_tokens"));
  const jwt = mint.auth.replace(/^Bearer /, "");
  const v = await verifyJwt(jwt, agyPair.publicKey);
  assert.ok(v.ok, "JWT verifies with the agy App's public key");
  assert.ok(!(await verifyJwt(jwt, claudePair.publicKey)).ok, "JWT does not verify with claude key");
  assert.ok(!(await verifyJwt(jwt, ciPair.publicKey)).ok, "JWT does not verify with ci key");
  assert.equal(v.claims.iss, AGY_APP_ID);

  const userCall = gh.calls.find((c) => c.url === `https://api.github.com/users/${AGY_APP_SLUG}%5Bbot%5D`);
  assert.ok(userCall, "looks up agy bot user ID via /users/<slug>%5Bbot%5D");
  assert.equal(e.AUDIT.rows.at(-1).agent, "agy");
});

test("/token refuses ci, unknown, non-string or missing agent with 400 bad_agent", async () => {
  const cases = [
    { repo: "Jomaries777/sandbox-node-local", agent: "ci" },
    { agent: "ci" },
    { repo: "Jomaries777/sandbox-node-local" },
    {},
    { repo: "Jomaries777/sandbox-node-local", agent: "" },
    { repo: "Jomaries777/sandbox-node-local", agent: "CLAUDE" },
    { repo: "Jomaries777/sandbox-node-local", agent: "bot" },
    { repo: "Jomaries777/sandbox-node-local", agent: "toString" },
    { repo: "Jomaries777/sandbox-node-local", agent: "constructor" },
    { repo: "Jomaries777/sandbox-node-local", agent: "__proto__" },
    { repo: "Jomaries777/sandbox-node-local", agent: null },
    { repo: "Jomaries777/sandbox-node-local", agent: 42 },
    { repo: "Jomaries777/sandbox-node-local", agent: ["claude"] },
  ];
  for (const payload of cases) {
    const { res, body, e, gh } = await call(req(payload));
    assert.equal(res.status, 400, `payload ${JSON.stringify(payload)}`);
    assert.equal(body.error, "bad_agent", `payload ${JSON.stringify(payload)}`);
    assert.ok(!gh.calls.some((c) => c.url.includes("/repos/")), "no repo lookup");
    assert.ok(!gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
    assert.ok(!gh.calls.some((c) => c.url.includes("/users/")), "no user lookup");
    assert.equal(e.AUDIT.rows.at(-1).reason, "bad_agent");
    assert.equal(e.AUDIT.rows.at(-1).agent, null);
  }
});

test("bot user ID lookup failures become 502 github_error", async () => {
  let r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env(), github({ userStatus: 500 }));
  assert.equal(r.res.status, 502);
  assert.equal(r.body.error, "github_error");
  assert.equal(r.e.AUDIT.rows.at(-1).agent, "claude");
  assert.equal(r.e.AUDIT.rows.at(-1).outcome, "refused");
  assert.equal(r.e.AUDIT.rows.at(-1).expires_at, null);

  r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "agy" }), env(), github({ userId: "not-a-number" }));
  assert.equal(r.res.status, 502);
  assert.equal(r.body.error, "github_error");
  assert.equal(r.e.AUDIT.rows.at(-1).agent, "agy");

  for (const badId of [0, -5, 1.5, null]) {
    r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env(), github({ userId: badId }));
    assert.equal(r.res.status, 502, `userId ${JSON.stringify(badId)}`);
    assert.equal(r.body.error, "github_error");
  }
});

test("missing key or placeholder/invalid App config fails closed before calling GitHub", async () => {
  for (const badKey of [undefined, "", "   \n"]) {
    const r = await call(
      req({ repo: "Jomaries777/sandbox-node-local", agent: "agy" }),
      env({ AGY_KEY_PKCS8: badKey }),
    );
    assert.equal(r.res.status, 500, `key ${JSON.stringify(badKey)}`);
    assert.equal(r.body.error, "missing_key");
    assert.equal(r.e.AUDIT.rows.at(-1).agent, "agy");
    assert.ok(!r.gh.calls.some((c) => c.url.includes("/repos/")), "no repo call");
    assert.ok(!r.gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
  }

  for (const over of [
    { CLAUDE_APP_ID: "0" },
    { CLAUDE_APP_ID: "" },
    { CLAUDE_APP_ID: undefined },
    { CLAUDE_APP_SLUG: "" },
    { CLAUDE_APP_SLUG: undefined },
    { CLAUDE_APP_SLUG: "bad/slug" },
  ]) {
    const r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env(over));
    assert.equal(r.res.status, 500, `over ${JSON.stringify(over)}`);
    assert.equal(r.body.error, "misconfigured");
    assert.equal(r.e.AUDIT.rows.at(-1).agent, "claude");
    assert.ok(!r.gh.calls.some((c) => c.url.includes("/repos/")), "no repo call");
    assert.ok(!r.gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
    assert.ok(!r.gh.calls.some((c) => c.url.includes("/users/")), "no user lookup");
  }

  const gh = github();
  const direct = await mintToken(env(), { fetch: gh.fetch }, "ci", "sandbox-node-local", NOW);
  assert.deepEqual(direct, { error: [400, { error: "bad_agent" }] });
  assert.equal(gh.calls.length, 0);
});

test("another GitHub user is refused", async () => {
  const { res, body, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, OTHER_CRED));
  assert.equal(res.status, 403);
  assert.equal(body.error, "not_owner");
  assert.ok(!gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
});

test("no token and a bad token are refused", async () => {
  let r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, null));
  assert.equal(r.res.status, 401);
  assert.equal(r.body.error, "no_token");
  assert.equal(r.gh.calls.length, 0, "no GitHub call without a token");
  r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, "nonsense"));
  assert.equal(r.res.status, 401);
  assert.equal(r.body.error, "bad_token");
});

test("an owner token the login App did not issue is refused", async () => {
  const { res, body, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, OWNER_OTHER_APP));
  assert.equal(res.status, 401);
  assert.equal(body.error, "bad_token");
  assert.ok(!gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
});

test("the token check uses the login App's client credentials", async () => {
  const { res } = await call(
    req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }),
    env({ LOGIN_CLIENT_SECRET: "wrong-secret-x" }),
  );
  assert.equal(res.status, 401, "a wrong client secret identifies nobody");
});

test("repo names are validated before the repo is looked up", async () => {
  for (const repo of ["Jomaries777/..", "Jomaries777/.", "sandbox-node-local", "a/b/c", "", "Jomaries777/" + "x".repeat(101), "Jomaries777/a b", 42, null]) {
    const { res, body, e, gh } = await call(req({ repo, agent: "agy" }));
    assert.equal(res.status, 400, `repo ${JSON.stringify(repo)}`);
    assert.equal(body.error, "bad_repo");
    assert.equal(e.AUDIT.rows.at(-1).agent, "agy");
    assert.ok(!gh.calls.some((c) => c.url.includes("/repos/")), "no repo call for a bad name");
  }
  const bad = await call(req(null, OWNER_CRED, { raw: "{not json" }));
  assert.equal(bad.res.status, 400);
  assert.equal(bad.body.error, "bad_json");
});

test("a repo of another owner is refused, never mapped to the owner's", async () => {
  const { res, body, gh } = await call(req({ repo: "other-org/sandbox-node-local", agent: "claude" }));
  assert.equal(res.status, 400);
  assert.equal(body.error, "wrong_owner");
  assert.ok(!gh.calls.some((c) => c.url.includes("/repos/")), "no repo lookup");
  const ok = await call(req({ repo: "jomaries777/sandbox-node-local", agent: "claude" }));
  assert.equal(ok.res.status, 200, "the owner's login is matched without case");
});

test("refused requests count toward the hourly limit too", async () => {
  const e = env();
  for (let i = 0; i < 30; i++) {
    const { res } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e, github({ installStatus: 404 }));
    assert.equal(res.status, 404);
  }
  const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e);
  assert.equal(res.status, 429);
  assert.equal(body.error, "rate_limited");
});

test("throttled requests write no audit rows", async () => {
  const e = env();
  for (let i = 0; i < 30; i++) await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e);
  for (let i = 0; i < 5; i++) {
    const { res } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e);
    assert.equal(res.status, 429);
  }
  assert.equal(e.AUDIT.rows.length, 30, "only the 30 answered requests are stored");
});

test("another GitHub user gets one audited refusal an hour, then no writes", async () => {
  const e = env();
  const first = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, OTHER_CRED), e);
  assert.equal(first.res.status, 403);
  for (let i = 0; i < 10; i++) {
    const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, OTHER_CRED), e);
    assert.equal(res.status, 429);
    assert.equal(body.error, "rate_limited");
  }
  assert.equal(e.AUDIT.rows.length, 1);
  const owner = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e);
  assert.equal(owner.res.status, 200, "the owner is not limited by others");
});

test("without a working audit database nothing is issued", async () => {
  let r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env({ AUDIT: undefined }));
  assert.equal(r.res.status, 503);
  assert.equal(r.body.error, "audit_unavailable");
  assert.equal(r.gh.calls.length, 0, "refused before any GitHub call");
  const broken = d1({ failRead: true });
  r = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env({ AUDIT: broken }));
  assert.equal(r.res.status, 503);
  assert.equal(r.body.error, "audit_unavailable");
  assert.ok(!r.gh.calls.some((c) => c.url.includes("/access_tokens")), "no token minted");
  assert.equal(broken.rows.length, 0);
});

test("a body over 1 KB is refused", async () => {
  const { res, body } = await call(req(null, OWNER_CRED, { raw: JSON.stringify({ repo: "x", agent: "claude", pad: "y".repeat(2000) }) }));
  assert.equal(res.status, 413);
  assert.equal(body.error, "too_large");
});

test("a streamed body over 1 KB is refused without reading it all", async () => {
  const { res, body } = await call(req(null, OWNER_CRED, { stream: 100 }));
  assert.equal(res.status, 413);
  assert.equal(body.error, "too_large");
});

test("the kill switch refuses everything", async () => {
  const { res, body, gh } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env({ BROKER_ENABLED: "false" }));
  assert.equal(res.status, 503);
  assert.equal(body.error, "disabled");
  assert.equal(gh.calls.length, 0);
});

test("a repo without the bot installed is 404", async () => {
  const { res, body, e } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env(), github({ installStatus: 404 }));
  assert.equal(res.status, 404);
  assert.equal(body.error, "not_installed");
  assert.equal(e.AUDIT.rows.at(-1).agent, "claude");
});

test("GitHub failures become 502", async () => {
  const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), env(), github({ tokenStatus: 500 }));
  assert.equal(res.status, 502);
  assert.equal(body.error, "github_error");
});

test("the 31st token in an hour is rate limited across agents", async () => {
  const e = env();
  for (let i = 0; i < 30; i++) {
    const agent = i % 2 === 0 ? "claude" : "agy";
    const { res } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent }), e);
    assert.equal(res.status, 200);
  }
  const { res, body } = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e);
  assert.equal(res.status, 429);
  assert.equal(body.error, "rate_limited");
});

test("identified callers are audited with agent, anonymous refusals are not, and no token is stored", async () => {
  const e = env();
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "agy" }), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, OTHER_CRED), e);
  await call(req({ repo: "Jomaries777/..", agent: "agy" }), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, null), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, "nonsense"), e);
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }, OWNER_OTHER_APP), e);
  const rows = e.AUDIT.rows;
  assert.equal(rows.length, 4, "no, bad and foreign tokens leave no row");
  assert.deepEqual(
    rows.map((r) => [r.outcome, r.reason, r.caller_id, r.agent]),
    [
      ["issued", null, OWNER_ID, "claude"],
      ["issued", null, OWNER_ID, "agy"],
      ["refused", "not_owner", OTHER_ID, null],
      ["refused", "bad_repo", OWNER_ID, "agy"],
    ],
  );
  assert.equal(rows[0].ip, "203.0.113.9");
  const stored = JSON.stringify(rows);
  for (const secret of [OWNER_CRED, OTHER_CRED, INST_TOKEN, LOGIN_SECRET, claudePem, agyPem, ciPem]) {
    assert.ok(!stored.includes(secret), "audit holds no token or key");
  }
});

test("old audit rows are deleted now and then, not on every write", async () => {
  const e = env();
  e.AUDIT.rows.push({ ts: NOW - 91 * 24 * 3600 * 1000, caller_id: "1", endpoint: "token", agent: "claude", outcome: "issued" });
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e, github(), () => 0.5);
  assert.equal(e.AUDIT.rows.length, 2, "kept when this write doesn't prune");
  await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e, github(), () => 0);
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
