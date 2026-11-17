// Tests for POST /relay (spec 0002 FR-6, C3; S0002-8, 14). Offline: a fake
// GitHub repo keeps refs and commits in memory and records every call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { OWNER_ID, OTHER_CRED, OWNER_CRED, d1, github, env, req, call } from "./helpers.mjs";
import { resetSchemaCheck } from "../../broker/src/handler.js";

const R = "https://api.github.com/repos/Jomaries777/sandbox-node-local";
const MAIN = "a".repeat(40);
const BOT_HEAD = "b".repeat(40);
const OWNER_HEAD = "c".repeat(40);
const SPOOF_HEAD = "f".repeat(40);
const OTHER_COMMITTER_HEAD = "9".repeat(40);
const BOT = "jomaries777-agent-bot[bot]";
const b64 = (s) => Buffer.from(s).toString("base64");

// repo({ branches, failRef, openPr }): a fake repo behind the fake GitHub.
// branches maps a branch name to its head; commits know their authors.
function repo({ branches = {}, failRef, openPr = false } = {}) {
  const refs = { main: MAIN, ...branches };
  const commits = {
    [MAIN]: { login: "Jomaries777", tree: "t-main" },
    [BOT_HEAD]: { login: BOT, tree: "t-bot" },
    [OWNER_HEAD]: { login: "Jomaries777", tree: "t-owner" },
    // Pushed by someone with the bot's email: the login matches, but GitHub
    // didn't verify it.
    [SPOOF_HEAD]: { login: BOT, tree: "t-spoof", verified: false },
    // Verified, bot as author, but committed by someone else.
    [OTHER_COMMITTER_HEAD]: { login: BOT, tree: "t-other", verified: true, committer: "someone-else" },
  };
  let blobN = 0;
  const routes = (url, init, reply) => {
    if (!url.startsWith(R)) return undefined;
    const path = url.slice(R.length);
    const method = init.method || "GET";
    const body = init.body ? JSON.parse(init.body) : undefined;
    let m;
    if (method === "GET" && (m = /^\/git\/ref\/heads\/(.+)$/.exec(path))) {
      const sha = refs[m[1]];
      return sha ? reply(200, { object: { sha } }) : reply(404, { message: "Not Found" });
    }
    if (method === "GET" && (m = /^\/commits\/([0-9a-f]{40})$/.exec(path))) {
      const c = commits[m[1]];
      if (!c) return reply(404, {});
      return reply(200, {
        author: { login: c.login },
        // Like GitHub: a commit the App makes through the API has GitHub's
        // web-flow as committer (seen live on 2026-11-17, S0002-7).
        committer: { login: c.committer ?? (c.login === BOT ? "web-flow" : c.login) },
        commit: { tree: { sha: c.tree }, verification: { verified: c.verified ?? c.login === BOT } },
      });
    }
    if (method === "POST" && path === "/git/blobs") return reply(201, { sha: `blob${++blobN}` });
    if (method === "POST" && path === "/git/trees") return reply(201, { sha: "t-new" });
    if (method === "POST" && path === "/git/commits") {
      commits["d".repeat(40)] = { login: BOT, tree: body.tree };
      return reply(201, { sha: "d".repeat(40) });
    }
    if (method === "POST" && path === "/git/refs") {
      if (failRef) return reply(failRef, {});
      refs[body.ref.replace("refs/heads/", "")] = body.sha;
      return reply(201, {});
    }
    if (method === "PATCH" && (m = /^\/git\/refs\/heads\/(.+)$/.exec(path))) {
      if (failRef) return reply(failRef, {});
      refs[m[1]] = body.sha;
      return reply(200, {});
    }
    if (method === "GET" && path.startsWith("/pulls?")) {
      return reply(200, openPr ? [{ html_url: "https://github.com/x/pull/7" }] : []);
    }
    if (method === "POST" && path === "/pulls") return reply(201, { html_url: "https://github.com/x/pull/8" });
    return undefined;
  };
  return { gh: github({ routes }), refs };
}

function payload(over = {}) {
  return {
    repo: "Jomaries777/sandbox-node-local",
    branch: "test/relay-check",
    base: "main",
    parent: MAIN,
    message: "test: relay",
    files: [
      { path: "notes/hello.txt", content_b64: b64("secret-ish body 42\n") },
      { path: "scripts/run.sh", content_b64: b64("#!/bin/sh\n"), mode: "100755" },
      { path: "img/dot.png", content_b64: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe]).toString("base64") },
      { path: "old.txt", delete: true },
    ],
    pr: { title: "test: relay", body: "from the relay" },
    ...over,
  };
}

const relayReq = (p, cred = OWNER_CRED) => req(p, cred, { path: "/relay" });
const bodyOf = (gh, method, suffix) => {
  const c = gh.calls.find((x) => x.method === method && x.url === `${R}${suffix}`);
  return c && JSON.parse(c.body);
};
const repoCalls = (gh) => gh.calls.filter((c) => c.url.startsWith(R));

test("a new branch gets one bot commit and a draft PR", async () => {
  const { gh, refs } = repo();
  const { res, body, e } = await call(relayReq(payload()), env(), gh);
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.deepEqual(body, { commit: "d".repeat(40), branch: "test/relay-check", pr_url: "https://github.com/x/pull/8" });

  assert.deepEqual(bodyOf(gh, "POST", "/git/trees"), {
    base_tree: "t-main",
    tree: [
      { path: "notes/hello.txt", mode: "100644", type: "blob", content: "secret-ish body 42\n" },
      { path: "scripts/run.sh", mode: "100755", type: "blob", content: "#!/bin/sh\n" },
      { path: "img/dot.png", mode: "100644", type: "blob", sha: "blob1" },
      { path: "old.txt", mode: "100644", type: "blob", sha: null },
    ],
  });
  const commit = bodyOf(gh, "POST", "/git/commits");
  assert.deepEqual(commit, { message: "test: relay", tree: "t-new", parents: [MAIN] }, "no author: the App is author");
  assert.deepEqual(bodyOf(gh, "POST", "/git/refs"), { ref: "refs/heads/test/relay-check", sha: "d".repeat(40) });
  assert.equal(refs["test/relay-check"], "d".repeat(40));
  assert.deepEqual(bodyOf(gh, "POST", "/pulls"), {
    title: "test: relay",
    body: "from the relay",
    head: "test/relay-check",
    base: "main",
    draft: true,
  });

  const row = e.AUDIT.rows.at(-1);
  assert.equal(row.endpoint, "relay");
  assert.equal(row.outcome, "issued");
  assert.equal(row.branch, "test/relay-check");
  assert.equal(row.files, 4);
  assert.equal(row.paths, "notes/hello.txt,scripts/run.sh,img/dot.png,old.txt");
  const stored = JSON.stringify(e.AUDIT.rows);
  assert.ok(!stored.includes("secret-ish") && !stored.includes(b64("secret-ish body 42\n")), "no contents in the audit");
});

test("an existing bot branch moves fast-forward, and no second PR is opened", async () => {
  const { gh } = repo({ branches: { "test/relay-check": BOT_HEAD }, openPr: true });
  const { res, body } = await call(relayReq(payload({ parent: BOT_HEAD })), env(), gh);
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.equal(body.pr_url, "https://github.com/x/pull/7");
  assert.deepEqual(bodyOf(gh, "PATCH", "/git/refs/heads/test/relay-check"), { sha: "d".repeat(40), force: false });
  assert.equal(bodyOf(gh, "POST", "/git/trees").base_tree, "t-bot");
  assert.ok(!gh.calls.some((c) => c.method === "POST" && c.url === `${R}/pulls`));
});

test("bad paths are refused before any repo call", async () => {
  for (const path of [
    ".github/workflows/x.yml",
    ".GitHub/Workflows/x.yml",
    ".github/workflows",
    "../x",
    "a/../../x",
    "/etc/passwd",
    ".git/config",
    "sub/.GIT/hooks/pre-commit",
    "a//b",
    "./a",
    "a\\b",
    "a\nb",
    "",
    "x".repeat(401),
  ]) {
    const { gh } = repo();
    const { res, body } = await call(relayReq(payload({ files: [{ path, content_b64: b64("x") }] })), env(), gh);
    assert.equal(res.status, 400, `path ${JSON.stringify(path)}`);
    assert.equal(body.error, "path_denied");
    assert.equal(repoCalls(gh).length, 0, "no repo call");
  }
});

test("only feat/fix/docs/chore/test/ci branches, never main", async () => {
  for (const branch of ["main", "master", "release/x", "feat/", "feat/../main", "feat/x.lock", "feat/a//b", "Feat/x", "feat/.hidden"]) {
    const { gh } = repo();
    const { res, body } = await call(relayReq(payload({ branch })), env(), gh);
    assert.equal(res.status, 400, `branch ${branch}`);
    assert.equal(body.error, "bad_branch");
    assert.equal(repoCalls(gh).length, 0);
  }
});

test("a stale parent is refused, on a new and on an existing branch", async () => {
  let r = repo();
  let out = await call(relayReq(payload({ parent: "e".repeat(40) })), env(), r.gh);
  assert.equal(out.res.status, 409);
  assert.equal(out.body.error, "stale_parent");
  r = repo({ branches: { "test/relay-check": BOT_HEAD } });
  out = await call(relayReq(payload({ parent: MAIN })), env(), r.gh);
  assert.equal(out.res.status, 409);
  assert.equal(out.body.error, "stale_parent");
  assert.ok(!r.gh.calls.some((c) => c.url.endsWith("/git/commits")), "no commit made");
});

test("a branch whose head isn't the bot's is never moved", async () => {
  const { gh, refs } = repo({ branches: { "test/relay-check": OWNER_HEAD } });
  const { res, body } = await call(relayReq(payload({ parent: OWNER_HEAD })), env(), gh);
  assert.equal(res.status, 409);
  assert.equal(body.error, "not_bot_branch");
  assert.equal(refs["test/relay-check"], OWNER_HEAD);
  assert.ok(!gh.calls.some((c) => c.url.endsWith("/git/trees")));
});

test("a branch that moves during the relay is a stale parent", async () => {
  const { gh } = repo({ failRef: 422 });
  const { res, body } = await call(relayReq(payload()), env(), gh);
  assert.equal(res.status, 409);
  assert.equal(body.error, "stale_parent");
});

test("limits: files, blobs, modes, body size, fields", async () => {
  const bin = Buffer.from([0xff, 0xfe, 0x00]).toString("base64");
  const cases = [
    [{ files: Array.from({ length: 101 }, (_, i) => ({ path: `f${i}`, content_b64: b64("x") })) }, "bad_files"],
    [{ files: [] }, "bad_files"],
    [{ files: Array.from({ length: 11 }, (_, i) => ({ path: `b${i}`, content_b64: bin })) }, "too_many_blobs"],
    [{ files: [{ path: "l", content_b64: b64("x"), mode: "120000" }] }, "bad_mode"],
    [{ files: [{ path: "s", content_b64: b64("x"), mode: "160000" }] }, "bad_mode"],
    [{ files: [{ path: "x", content_b64: "not base64!" }] }, "bad_content"],
    [{ files: [{ path: "x", content_b64: b64("1") }, { path: "x", content_b64: b64("2") }] }, "path_denied"],
    [{ parent: "main" }, "bad_parent"],
    [{ parent: undefined }, "bad_parent"],
    [{ message: " " }, "bad_message"],
    [{ base: "../main" }, "bad_base"],
    [{ base: "test/relay-check" }, "bad_base"],
    [{ pr: { title: "" } }, "bad_pr"],
    [{ pr: { title: "t", draft: "no" } }, "bad_pr"],
    [{ repo: "someone-else/sandbox-node-local" }, "wrong_owner"],
  ];
  for (const [over, code] of cases) {
    const { gh } = repo();
    const { res, body } = await call(relayReq(payload(over)), env(), gh);
    assert.equal(res.status, 400, `${code}: ${JSON.stringify(over).slice(0, 80)}`);
    assert.equal(body.error, code);
    assert.equal(repoCalls(gh).length, 0);
  }
  const big = { files: [{ path: "big", content_b64: "A".repeat(1024 * 1024 + 4) }] };
  const { res, body } = await call(relayReq(payload(big)), env(), repo().gh);
  assert.equal(res.status, 413);
  assert.equal(body.error, "too_large");
});

test("a draft PR is the default, and draft:false is honoured", async () => {
  const { gh } = repo();
  await call(relayReq(payload({ pr: { title: "t", draft: false } })), env(), gh);
  assert.equal(bodyOf(gh, "POST", "/pulls").draft, false);
  const r2 = repo();
  await call(relayReq(payload({ pr: undefined })), env(), r2.gh);
  assert.ok(!r2.gh.calls.some((c) => c.url.includes("/pulls")), "no PR without pr");
});

test("relay shares the identity checks and has its own hourly limit", async () => {
  let out = await call(relayReq(payload(), OTHER_CRED), env(), repo().gh);
  assert.equal(out.res.status, 403);
  assert.equal(out.body.error, "not_owner");
  out = await call(relayReq(payload(), null), env(), repo().gh);
  assert.equal(out.res.status, 401);
  out = await call(relayReq(payload()), env({ BROKER_ENABLED: "false" }), repo().gh);
  assert.equal(out.res.status, 503);
  out = await call(relayReq(payload()), env({ AUDIT: undefined }), repo().gh);
  assert.equal(out.body.error, "audit_unavailable");

  const e = env();
  for (let i = 0; i < 20; i++) {
    const { res } = await call(relayReq(payload()), e, repo().gh);
    assert.equal(res.status, 200);
  }
  out = await call(relayReq(payload()), e, repo().gh);
  assert.equal(out.res.status, 429);
  // /token keeps its own budget.
  const tok = await call(req({ repo: "Jomaries777/sandbox-node-local" }), e);
  assert.equal(tok.res.status, 200);
  assert.ok(e.AUDIT.rows.every((r) => r.caller_id === OWNER_ID));
});

test("a broker deployed before its migration refuses instead of losing audit rows", async () => {
  resetSchemaCheck();
  const old = d1({ oldSchema: true });
  for (const r of [relayReq(payload()), req({ repo: "Jomaries777/sandbox-node-local" })]) {
    const { res, body, gh } = await call(r, env({ AUDIT: old }), repo().gh);
    assert.equal(res.status, 503);
    assert.equal(body.error, "audit_unavailable");
    assert.equal(gh.calls.length, 0, "refused before any GitHub call");
  }
  resetSchemaCheck();
  const ok = await call(relayReq(payload()), env(), repo().gh);
  assert.equal(ok.res.status, 200, "the check passes once the columns exist");
});

test("a tree GitHub rejects is a clear 400, and nothing moves", async () => {
  const { gh, refs } = repo();
  const real = gh.fetch;
  gh.fetch = async (url, init = {}) =>
    url === `${R}/git/trees` ? new Response("{}", { status: 422 }) : real(url, init);
  const { res, body } = await call(relayReq(payload()), env(), gh);
  assert.equal(res.status, 400);
  assert.equal(body.error, "tree_rejected");
  assert.equal(refs["test/relay-check"], undefined);
});

test("a head that only claims to be the bot's (unverified) is refused", async () => {
  const { gh, refs } = repo({ branches: { "test/relay-check": SPOOF_HEAD } });
  const { res, body } = await call(relayReq(payload({ parent: SPOOF_HEAD })), env(), gh);
  assert.equal(res.status, 409);
  assert.equal(body.error, "not_bot_branch");
  assert.equal(refs["test/relay-check"], SPOOF_HEAD);
});

test("a leading byte-order mark is kept in text files", async () => {
  const { gh } = repo();
  const bom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("x\n")]).toString("base64");
  const { res } = await call(relayReq(payload({ files: [{ path: "bom.txt", content_b64: bom }] })), env(), gh);
  assert.equal(res.status, 200);
  const entry = bodyOf(gh, "POST", "/git/trees").tree[0];
  assert.equal(entry.content, "\ufeffx\n");
});

test("text with NUL bytes goes through a blob", async () => {
  const { gh } = repo();
  const nul = Buffer.from("a\0b").toString("base64");
  const { res } = await call(relayReq(payload({ files: [{ path: "n.bin", content_b64: nul }] })), env(), gh);
  assert.equal(res.status, 200);
  assert.deepEqual(bodyOf(gh, "POST", "/git/trees").tree[0], { path: "n.bin", mode: "100644", type: "blob", sha: "blob1" });
});

test("/relay/ (trailing slash) is the same endpoint, for path-limited secrets", async () => {
  const { gh } = repo();
  const { res, body, e } = await call(req(payload(), OWNER_CRED, { path: "/relay/" }), env(), gh);
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.equal(e.AUDIT.rows.at(-1).endpoint, "relay", "same audit row and hourly limit as /relay");
});

test("a Verified head committed by anyone but the bot or web-flow is refused", async () => {
  const { gh, refs } = repo({ branches: { "test/relay-check": OTHER_COMMITTER_HEAD } });
  const { res, body } = await call(relayReq(payload({ parent: OTHER_COMMITTER_HEAD })), env(), gh);
  assert.equal(res.status, 409);
  assert.equal(body.error, "not_bot_branch");
  assert.equal(refs["test/relay-check"], OTHER_COMMITTER_HEAD);
});
