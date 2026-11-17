// POST /relay (spec 0002 FR-6, C3): a caller that can't push as the bot (a
// cloud Claude Code session) sends changed files; the broker makes one commit
// on a feat/fix/docs/chore/test/ci branch as the bot, and optionally a draft
// PR. Every rule below is checked before any GitHub call; GitHub's own limits
// (no `workflows` permission, the ruleset on main) stand behind them.

import { gh } from "./github.js";

// 1 MB, not the spec's 2 MB: parsing and decoding 2 MB took about 6 ms of
// the free plan's 10 ms CPU in a local benchmark (spec C7 allows lowering it).
export const RELAY_MAX_BODY = 1024 * 1024; // bytes
const MAX_FILES = 100;
// Binary files need one blob call each; 10 keeps a relay well inside the
// Workers free plan's 50 subrequests (about 21 at most).
const MAX_BLOBS = 10;
const MAX_PATHS_AUDIT = 2000; // characters of the comma-joined paths
const BRANCH_RE = /^(feat|fix|docs|chore|test|ci)\/[a-z0-9._/-]{1,80}$/;
// The base is only read (the new branch starts from it), so any plain ref
// name will do.
const BASE_RE = /^[A-Za-z0-9._/-]{1,100}$/;
const SHA_RE = /^[0-9a-f]{40}$/;
const MODES = new Set(["100644", "100755"]);

function err(status, code) {
  return [status, { error: code }];
}

// A ref name git and GitHub accept, with none of the forms that could mean
// something else.
function refOk(name) {
  return (
    !name.includes("..") &&
    !name.includes("//") &&
    !name.endsWith("/") &&
    !name.endsWith(".") &&
    !name.endsWith(".lock") &&
    !name.split("/").some((seg) => seg.startsWith("."))
  );
}

// pathOk: a repo-relative path the relay may write. Refuses workflows, .git,
// absolute paths, traversal and odd characters.
export function pathOk(path) {
  if (typeof path !== "string" || path.length === 0 || path.length > 400) return false;
  // eslint-disable-next-line no-control-regex
  if (/[\x00-\x1f\x7f\\]/.test(path)) return false;
  if (path.startsWith("/")) return false;
  const segs = path.split("/");
  if (segs.some((s) => s === "" || s === "." || s === "..")) return false;
  if (segs.some((s) => s.toLowerCase() === ".git")) return false;
  const lower = path.toLowerCase();
  if (lower === ".github/workflows" || lower.startsWith(".github/workflows/")) return false;
  return true;
}

function b64ToBytes(b64) {
  if (typeof b64 !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(b64) || b64.length % 4 !== 0) return null;
  try {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

// validate: the whole payload, before any GitHub call. Returns { v } with the
// normalized fields, or { error }.
function validate(p) {
  const branch = p.branch;
  if (typeof branch !== "string" || !BRANCH_RE.test(branch) || !refOk(branch)) {
    return { error: err(400, "bad_branch") };
  }
  const base = p.base ?? "main";
  if (typeof base !== "string" || !BASE_RE.test(base) || !refOk(base) || base === branch) {
    return { error: err(400, "bad_base") };
  }
  if (typeof p.parent !== "string" || !SHA_RE.test(p.parent)) return { error: err(400, "bad_parent") };
  if (typeof p.message !== "string" || p.message.trim() === "" || p.message.length > 5000) {
    return { error: err(400, "bad_message") };
  }
  if (!Array.isArray(p.files) || p.files.length === 0 || p.files.length > MAX_FILES) {
    return { error: err(400, "bad_files") };
  }
  const seen = new Set();
  const files = [];
  let blobs = 0;
  for (const f of p.files) {
    if (f === null || typeof f !== "object" || !pathOk(f.path) || seen.has(f.path)) {
      return { error: err(400, "path_denied") };
    }
    seen.add(f.path);
    if (f.delete === true) {
      files.push({ path: f.path, delete: true });
      continue;
    }
    const mode = f.mode ?? "100644";
    if (!MODES.has(mode)) return { error: err(400, "bad_mode") };
    const bytes = b64ToBytes(f.content_b64);
    if (bytes === null) return { error: err(400, "bad_content") };
    let text = null;
    try {
      // ignoreBOM keeps a leading byte-order mark, so the commit matches the file.
      text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
      // NUL is valid UTF-8 but not text: send such files as blobs.
      if (text.includes("\0")) text = null;
    } catch {
      text = null;
    }
    if (text === null && ++blobs > MAX_BLOBS) return { error: err(400, "too_many_blobs") };
    files.push({ path: f.path, mode, text, b64: f.content_b64 });
  }
  let pr = null;
  if (p.pr !== undefined && p.pr !== null) {
    const { title, body = "", draft = true } = p.pr;
    if (
      typeof title !== "string" ||
      title.trim() === "" ||
      title.length > 256 ||
      typeof body !== "string" ||
      body.length > 20000 ||
      typeof draft !== "boolean"
    ) {
      return { error: err(400, "bad_pr") };
    }
    pr = { title, body, draft };
  }
  return { v: { branch, base, parent: p.parent, message: p.message, files, pr } };
}

export async function relay(env, deps, p, row, nowMs, { checkRepo, mintToken }) {
  const repo = checkRepo(env, p.repo, row);
  if (repo.error) return repo.error;
  const checked = validate(p);
  if (checked.error) return checked.error;
  const { branch, base, parent, message, files, pr } = checked.v;
  row.branch = branch;
  row.files = files.length;
  row.paths = files.map((f) => f.path).join(",").slice(0, MAX_PATHS_AUDIT);

  const minted = await mintToken(env, deps, repo.name, nowMs);
  if (minted.error) return minted.error;
  const auth = `Bearer ${minted.token}`;
  const r = `/repos/${env.OWNER_LOGIN}/${repo.name}`;
  const call = (path, opts = {}) => gh(deps.fetch, `${r}${path}`, { auth, ...opts });
  const bot = `${env.APP_SLUG}[bot]`;

  // Where the commit goes, and whether it may.
  const head = await call(`/git/ref/heads/${branch}`);
  const exists = head.status === 200;
  if (!exists && head.status !== 404) return err(502, "github_error");
  if (exists) {
    if (head.data?.object?.sha !== parent) return err(409, "stale_parent");
  } else {
    const baseRef = await call(`/git/ref/heads/${base}`);
    if (baseRef.status === 404) return err(400, "bad_base");
    if (baseRef.status !== 200) return err(502, "github_error");
    // A stale base would silently undo newer commits on it.
    if (baseRef.data?.object?.sha !== parent) return err(409, "stale_parent");
  }
  const pc = await call(`/commits/${parent}`);
  if (pc.status !== 200 || !pc.data?.commit?.tree?.sha) return err(502, "github_error");
  // The relay never moves someone else's branch. A commit the App made
  // through the API has the bot as author and GitHub (web-flow) as committer,
  // and GitHub verifies it. The author login comes from the commit's email,
  // which anyone who can push could fake, so the Verified mark is required too.
  const botHead =
    pc.data.author?.login === bot &&
    [bot, "web-flow"].includes(pc.data.committer?.login) &&
    pc.data.commit?.verification?.verified === true;
  if (exists && !botHead) {
    return err(409, "not_bot_branch");
  }

  // Tree: text inline, binary as blobs, deletes as sha null.
  const tree = [];
  for (const f of files) {
    if (f.delete) {
      // GitHub ignores the mode of a deleted (sha null) entry.
      tree.push({ path: f.path, mode: "100644", type: "blob", sha: null });
    } else if (f.text !== null) {
      tree.push({ path: f.path, mode: f.mode, type: "blob", content: f.text });
    } else {
      const blob = await call("/git/blobs", { method: "POST", body: { content: f.b64, encoding: "base64" } });
      if (blob.status !== 201 || !blob.data?.sha) return err(502, "github_error");
      tree.push({ path: f.path, mode: f.mode, type: "blob", sha: blob.data.sha });
    }
  }
  const t = await call("/git/trees", { method: "POST", body: { base_tree: pc.data.commit.tree.sha, tree } });
  // 422: GitHub refused the tree, e.g. deleting a path that isn't there.
  if (t.status === 422) return err(400, "tree_rejected");
  if (t.status !== 201 || !t.data?.sha) return err(502, "github_error");
  // No author or committer: the App is both, and GitHub marks it Verified.
  const c = await call("/git/commits", { method: "POST", body: { message, tree: t.data.sha, parents: [parent] } });
  if (c.status !== 201 || !c.data?.sha) return err(502, "github_error");
  const commit = c.data.sha;

  const ref = exists
    ? await call(`/git/refs/heads/${branch}`, { method: "PATCH", body: { sha: commit, force: false } })
    : await call("/git/refs", { method: "POST", body: { ref: `refs/heads/${branch}`, sha: commit } });
  // 422: the branch moved (or appeared) since the check above.
  if (ref.status === 422) return err(409, "stale_parent");
  if (ref.status !== (exists ? 200 : 201)) return err(502, "github_error");

  let prUrl = null;
  if (pr) {
    const open = await call(`/pulls?head=${encodeURIComponent(`${env.OWNER_LOGIN}:${branch}`)}&state=open`);
    if (open.status !== 200 || !Array.isArray(open.data)) return err(502, "github_error");
    if (open.data.length > 0) {
      prUrl = open.data[0].html_url ?? null;
    } else {
      const made = await call("/pulls", {
        method: "POST",
        body: { title: pr.title, body: pr.body, head: branch, base, draft: pr.draft },
      });
      if (made.status !== 201) return err(502, "github_error");
      prUrl = made.data?.html_url ?? null;
    }
  }
  return [200, { commit, branch, pr_url: prUrl }];
}
