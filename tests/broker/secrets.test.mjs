// Tests for POST /secrets (spec 0002 FR-8; spec 0003 FR-4, C2, NFR-5). Offline:
// a fake GitHub holds libsodium keypairs as the repos' secret public keys, so
// every sealed value is opened with libsodium's crypto_box_seal_open, the same
// operation GitHub runs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { OTHER_CRED, OWNER_CRED, OWNER_ID, claudePem, ciPem, agyPem, github, env, req, call } from "./helpers.mjs";

const require = createRequire(new URL("../../broker/package.json", import.meta.url));
const sodium = require("libsodium-wrappers");
await sodium.ready;

const R = "https://api.github.com/repos/Jomaries777/sandbox-node-local";
const GH_OWNER = ["gh", "owner", "token", "value", "x"].join("-");
const GH_OTHER = ["gh", "other", "token", "value", "x"].join("-");

// repoKeys({ deny, putStatus }): a fake GitHub with one keypair per app and every PUT it saw.
function repoKeys({ deny, putStatus = 201 } = {}) {
  const keys = {};
  for (const app of ["actions", "dependabot"]) keys[app] = sodium.crypto_box_keypair();
  const puts = [];
  const routes = (url, init, reply) => {
    const auth = init.headers?.Authorization || "";
    if (url === "https://api.github.com/user") {
      if (auth === `Bearer ${GH_OWNER}`) return reply(200, { id: Number(OWNER_ID), login: "Jomaries777" });
      if (auth === `Bearer ${GH_OTHER}`) return reply(200, { id: 999, login: "someone" });
      return reply(401, {});
    }
    if (!url.startsWith(R)) return undefined;
    if (auth !== `Bearer ${GH_OWNER}`) return reply(401, {});
    let m;
    if ((m = /^\/(actions|dependabot)\/secrets\/public-key$/.exec(url.slice(R.length)))) {
      if (deny === m[1]) return reply(403, { message: "Resource not accessible" });
      const k = sodium.to_base64(keys[m[1]].publicKey, sodium.base64_variants.ORIGINAL);
      return reply(200, { key: k, key_id: `kid-${m[1]}` });
    }
    if ((m = /^\/(actions|dependabot)\/secrets\/([A-Z0-9_]+)$/.exec(url.slice(R.length))) && init.method === "PUT") {
      puts.push({ app: m[1], secret: m[2], body: JSON.parse(init.body) });
      return new Response(null, { status: putStatus });
    }
    return undefined;
  };
  return { gh: github({ routes }), keys, puts };
}

const open = (keys, app, b64) =>
  sodium.to_string(
    sodium.crypto_box_seal_open(sodium.from_base64(b64, sodium.base64_variants.ORIGINAL), keys[app].publicKey, keys[app].privateKey),
  );
const secretsReq = (body, { cred = OWNER_CRED, ghToken = GH_OWNER } = {}) =>
  req(body, cred, { path: "/secrets", extraHeaders: ghToken ? { "X-GitHub-Token": ghToken } : {} });
const CLAUDE_BODY = { repo: "Jomaries777/sandbox-node-local", key: "claude" };
const CI_BODY = { repo: "Jomaries777/sandbox-node-local", key: "ci" };

test("key: claude writes only the Actions secret CLAUDE_APP_PRIVATE_KEY", async () => {
  const { gh, keys, puts } = repoKeys();
  const { res, body, e } = await call(secretsReq(CLAUDE_BODY), env(), gh);
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.deepEqual(body, { key: "claude", app: "actions", secret: "CLAUDE_APP_PRIVATE_KEY" });
  assert.equal(puts.length, 1);
  assert.equal(puts[0].app, "actions");
  assert.equal(puts[0].secret, "CLAUDE_APP_PRIVATE_KEY");
  assert.equal(puts[0].body.key_id, "kid-actions");
  assert.equal(open(keys, "actions", puts[0].body.encrypted_value), claudePem);
  assert.ok(!gh.calls.some((c) => c.url.includes("/dependabot/")), "never touches Dependabot secrets");

  const row = e.AUDIT.rows.at(-1);
  assert.equal(row.endpoint, "secrets");
  assert.equal(row.agent, "claude");
  assert.equal(row.outcome, "issued");
  assert.equal(row.paths, "actions");
  const stored = JSON.stringify(e.AUDIT.rows) + JSON.stringify(body);
  for (const secret of [GH_OWNER, "PRIVATE KEY", puts[0].body.encrypted_value, claudePem, ciPem, agyPem]) {
    assert.ok(!stored.includes(secret), "no token, key or sealed value stored or returned");
  }
});

test("key: ci writes only the Dependabot secret CI_APP_PRIVATE_KEY", async () => {
  const { gh, keys, puts } = repoKeys();
  const { res, body, e } = await call(secretsReq(CI_BODY), env(), gh);
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.deepEqual(body, { key: "ci", app: "dependabot", secret: "CI_APP_PRIVATE_KEY" });
  assert.equal(puts.length, 1);
  assert.equal(puts[0].app, "dependabot");
  assert.equal(puts[0].secret, "CI_APP_PRIVATE_KEY");
  assert.equal(puts[0].body.key_id, "kid-dependabot");
  assert.equal(open(keys, "dependabot", puts[0].body.encrypted_value), ciPem);
  assert.ok(!gh.calls.some((c) => c.url.includes("/actions/")), "never touches Actions secrets");

  const row = e.AUDIT.rows.at(-1);
  assert.equal(row.endpoint, "secrets");
  assert.equal(row.agent, "ci");
  assert.equal(row.outcome, "issued");
  assert.equal(row.paths, "dependabot");
});

test("the caller cannot choose another target, secret name or public key", async () => {
  const evil = sodium.crypto_box_keypair();
  const evilPk = sodium.to_base64(evil.publicKey, sodium.base64_variants.ORIGINAL);

  const ci = repoKeys();
  let r = await call(
    secretsReq({
      ...CI_BODY,
      apps: ["actions"],
      app: "actions",
      target: "actions",
      secret: "CLAUDE_APP_PRIVATE_KEY",
      public_key: evilPk,
    }),
    env(),
    ci.gh,
  );
  assert.equal(r.res.status, 200);
  assert.equal(ci.puts.length, 1);
  assert.equal(ci.puts[0].app, "dependabot");
  assert.equal(ci.puts[0].secret, "CI_APP_PRIVATE_KEY");
  assert.equal(open(ci.keys, "dependabot", ci.puts[0].body.encrypted_value), ciPem);
  assert.throws(() =>
    sodium.crypto_box_seal_open(sodium.from_base64(ci.puts[0].body.encrypted_value, sodium.base64_variants.ORIGINAL), evil.publicKey, evil.privateKey),
  );

  const claude = repoKeys();
  r = await call(
    secretsReq({
      ...CLAUDE_BODY,
      apps: ["dependabot"],
      app: "dependabot",
      target: "dependabot",
      secret: "CI_APP_PRIVATE_KEY",
      public_key: evilPk,
    }),
    env(),
    claude.gh,
  );
  assert.equal(r.res.status, 200);
  assert.equal(claude.puts.length, 1);
  assert.equal(claude.puts[0].app, "actions");
  assert.equal(claude.puts[0].secret, "CLAUDE_APP_PRIVATE_KEY");
  assert.equal(open(claude.keys, "actions", claude.puts[0].body.encrypted_value), claudePem);
});

test("only broker/src/secrets.js reads CI_KEY_PKCS8", () => {
  const srcDir = fileURLToPath(new URL("../../broker/src", import.meta.url));
  const files = readdirSync(srcDir, { recursive: true }).filter((f) => /\.(c|m)?[jt]s$/.test(f));
  const readers = files.filter((f) => readFileSync(`${srcDir}/${f}`, "utf8").includes("CI_KEY_PKCS8"));
  assert.deepEqual(readers, ["secrets.js"]);
});

test("the GitHub token must be the owner's", async () => {
  let r = await call(secretsReq(CLAUDE_BODY, { ghToken: GH_OTHER }), env(), repoKeys().gh);
  assert.equal(r.res.status, 403);
  assert.equal(r.body.error, "github_token_not_owner");
  assert.equal(r.e.AUDIT.rows.at(-1).agent, "claude");
  r = await call(secretsReq(CI_BODY, { ghToken: null }), env(), repoKeys().gh);
  assert.equal(r.res.status, 400);
  assert.equal(r.body.error, "no_github_token");
  assert.equal(r.e.AUDIT.rows.at(-1).agent, "ci");
  r = await call(secretsReq(CLAUDE_BODY, { ghToken: "nonsense-token-value-123" }), env(), repoKeys().gh);
  assert.equal(r.res.status, 401);
  assert.equal(r.body.error, "bad_github_token");
});

test("only the owner's identity, only the owner's repos, only claude or ci keys", async () => {
  let r = await call(secretsReq(CLAUDE_BODY, { cred: OTHER_CRED }), env(), repoKeys().gh);
  assert.equal(r.res.status, 403);
  assert.equal(r.body.error, "not_owner");
  r = await call(secretsReq({ ...CLAUDE_BODY, repo: "someone-else/x" }), env(), repoKeys().gh);
  assert.equal(r.res.status, 400);
  assert.equal(r.body.error, "wrong_owner");
  assert.equal(r.e.AUDIT.rows.at(-1).agent, "claude");

  for (const body of [
    { repo: "Jomaries777/sandbox-node-local" },
    { repo: "Jomaries777/sandbox-node-local", apps: ["actions", "dependabot"] },
    { repo: "Jomaries777/sandbox-node-local", key: "agy" },
    { repo: "Jomaries777/sandbox-node-local", key: "CLAUDE" },
    { repo: "Jomaries777/sandbox-node-local", key: "CI" },
    { repo: "Jomaries777/sandbox-node-local", key: "" },
    { repo: "Jomaries777/sandbox-node-local", key: "toString" },
    { repo: "Jomaries777/sandbox-node-local", key: "__proto__" },
    { repo: "Jomaries777/sandbox-node-local", key: null },
    { repo: "Jomaries777/sandbox-node-local", key: ["claude"] },
    { key: "agy" },
  ]) {
    const { gh, puts } = repoKeys();
    r = await call(secretsReq(body), env(), gh);
    assert.equal(r.res.status, 400, JSON.stringify(body));
    assert.equal(r.body.error, "bad_key", JSON.stringify(body));
    assert.deepEqual(puts, []);
    assert.equal(r.e.AUDIT.rows.at(-1).agent, null);
  }
});

test("a missing or whitespace-only Worker key refuses without writing an empty secret", async () => {
  for (const badKey of [undefined, "", "  \n"]) {
    const { gh, puts } = repoKeys();
    const r = await call(secretsReq(CI_BODY), env({ CI_KEY_PKCS8: badKey }), gh);
    assert.equal(r.res.status, 500, `key ${JSON.stringify(badKey)}`);
    assert.equal(r.body.error, "missing_key");
    assert.equal(r.e.AUDIT.rows.at(-1).agent, "ci");
    assert.deepEqual(puts, []);
  }
});

test("updating an existing secret (HTTP 204 from GitHub) succeeds", async () => {
  const { gh, puts } = repoKeys({ putStatus: 204 });
  const r = await call(secretsReq(CLAUDE_BODY), env(), gh);
  assert.equal(r.res.status, 200);
  assert.deepEqual(r.body, { key: "claude", app: "actions", secret: "CLAUDE_APP_PRIVATE_KEY" });
  assert.equal(puts.length, 1);
});

test("GitHub refusals, kill switch and the hourly limit", async () => {
  let r = await call(secretsReq(CI_BODY), env(), repoKeys({ deny: "dependabot" }).gh);
  assert.equal(r.res.status, 403);
  assert.equal(r.body.error, "github_denied");
  assert.equal(r.e.AUDIT.rows.at(-1).agent, "ci");
  r = await call(secretsReq(CLAUDE_BODY), env({ BROKER_ENABLED: "false" }), repoKeys().gh);
  assert.equal(r.res.status, 503);
  const e = env();
  for (let i = 0; i < 10; i++) {
    const out = await call(secretsReq(i % 2 === 0 ? CLAUDE_BODY : CI_BODY), e, repoKeys().gh);
    assert.equal(out.res.status, 200);
  }
  r = await call(secretsReq(CLAUDE_BODY), e, repoKeys().gh);
  assert.equal(r.res.status, 429);
  const tok = await call(req({ repo: "Jomaries777/sandbox-node-local", agent: "claude" }), e);
  assert.equal(tok.res.status, 200, "/token keeps its own limit");
});
