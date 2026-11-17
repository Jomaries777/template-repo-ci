// Tests for POST /secrets (spec 0002 FR-8, C4; S0002-11 phase 2). Offline:
// a fake GitHub holds libsodium keypairs as the repos' secret public keys, so
// every sealed value is opened with libsodium's crypto_box_seal_open, the same
// operation GitHub runs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { OTHER_CRED, OWNER_CRED, OWNER_ID, pem, github, env, req, call } from "./helpers.mjs";

const require = createRequire(new URL("../../broker/package.json", import.meta.url));
const sodium = require("libsodium-wrappers");
await sodium.ready;

const R = "https://api.github.com/repos/Jomaries777/sandbox-node-local";
const GH_OWNER = ["gh", "owner", "token", "value", "x"].join("-");
const GH_OTHER = ["gh", "other", "token", "value", "x"].join("-");

// repoKeys({ deny }): a fake GitHub with one keypair per app and the PUTs it saw.
function repoKeys({ deny } = {}) {
  const keys = {};
  for (const app of ["actions", "dependabot"]) keys[app] = sodium.crypto_box_keypair();
  const puts = {};
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
    if ((m = /^\/(actions|dependabot)\/secrets\/BOT_APP_PRIVATE_KEY$/.exec(url.slice(R.length))) && init.method === "PUT") {
      puts[m[1]] = JSON.parse(init.body);
      return new Response(null, { status: 201 });
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
const BODY = { repo: "Jomaries777/sandbox-node-local", apps: ["actions", "dependabot"] };

test("sets both secrets, sealed so only GitHub's key opens them", async () => {
  const { gh, keys, puts } = repoKeys();
  const { res, body, e } = await call(secretsReq(BODY), env(), gh);
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.deepEqual(body, { set: ["actions", "dependabot"] });
  for (const app of ["actions", "dependabot"]) {
    assert.equal(puts[app].key_id, `kid-${app}`);
    assert.equal(open(keys, app, puts[app].encrypted_value), pem, `${app}: libsodium opens it to the App key`);
  }
  const row = e.AUDIT.rows.at(-1);
  assert.equal(row.endpoint, "secrets");
  assert.equal(row.outcome, "issued");
  assert.equal(row.paths, "actions,dependabot");
  const stored = JSON.stringify(e.AUDIT.rows) + JSON.stringify(body);
  for (const secret of [GH_OWNER, "PRIVATE KEY", puts.actions.encrypted_value]) {
    assert.ok(!stored.includes(secret), "no token, key or sealed value stored or returned");
  }
});

test("one app at a time, and a caller's public key is ignored", async () => {
  const { gh, keys, puts } = repoKeys();
  const evil = sodium.crypto_box_keypair();
  const evilPk = sodium.to_base64(evil.publicKey, sodium.base64_variants.ORIGINAL);
  const { res } = await call(secretsReq({ ...BODY, apps: ["dependabot"], key: evilPk, public_key: evilPk }), env(), gh);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(puts), ["dependabot"]);
  assert.equal(open(keys, "dependabot", puts.dependabot.encrypted_value), pem);
  assert.throws(() =>
    sodium.crypto_box_seal_open(sodium.from_base64(puts.dependabot.encrypted_value, sodium.base64_variants.ORIGINAL), evil.publicKey, evil.privateKey),
  );
});

test("the GitHub token must be the owner's", async () => {
  let r = await call(secretsReq(BODY, { ghToken: GH_OTHER }), env(), repoKeys().gh);
  assert.equal(r.res.status, 403);
  assert.equal(r.body.error, "github_token_not_owner");
  r = await call(secretsReq(BODY, { ghToken: null }), env(), repoKeys().gh);
  assert.equal(r.res.status, 400);
  assert.equal(r.body.error, "no_github_token");
  r = await call(secretsReq(BODY, { ghToken: "nonsense-token-value-123" }), env(), repoKeys().gh);
  assert.equal(r.res.status, 401);
  assert.equal(r.body.error, "bad_github_token");
});

test("only the owner's identity, only the owner's repos, only actions and dependabot", async () => {
  let r = await call(secretsReq(BODY, { cred: OTHER_CRED }), env(), repoKeys().gh);
  assert.equal(r.res.status, 403);
  assert.equal(r.body.error, "not_owner");
  r = await call(secretsReq({ ...BODY, repo: "someone-else/x" }), env(), repoKeys().gh);
  assert.equal(r.body.error, "wrong_owner");
  for (const apps of [[], ["codespaces"], ["actions", "actions"], "actions", ["actions", "dependabot", "x"]]) {
    const { gh, puts } = repoKeys();
    r = await call(secretsReq({ ...BODY, apps }), env(), gh);
    assert.equal(r.res.status, 400, JSON.stringify(apps));
    assert.equal(r.body.error, "bad_apps");
    assert.deepEqual(puts, {});
  }
});

test("GitHub refusals, kill switch and the hourly limit", async () => {
  let r = await call(secretsReq(BODY), env(), repoKeys({ deny: "dependabot" }).gh);
  assert.equal(r.res.status, 403);
  assert.equal(r.body.error, "github_denied");
  assert.deepEqual(r.body.set, ["actions"], "a partial failure names what was already set");
  r = await call(secretsReq(BODY), env({ BROKER_ENABLED: "false" }), repoKeys().gh);
  assert.equal(r.res.status, 503);
  const e = env();
  for (let i = 0; i < 10; i++) {
    const out = await call(secretsReq(BODY), e, repoKeys().gh);
    assert.equal(out.res.status, 200);
  }
  r = await call(secretsReq(BODY), e, repoKeys().gh);
  assert.equal(r.res.status, 429);
  const tok = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
  assert.equal(tok.res.status, 200, "/token keeps its own limit");
});
