// POST /secrets (spec 0002 FR-8; spec 0003 FR-4, C2): seal one App key into
// its single fixed repo secret target without the key ever leaving the broker.
//   key: "claude" -> Actions secret CLAUDE_APP_PRIVATE_KEY (CLAUDE_KEY_PKCS8)
//   key: "ci"     -> Dependabot secret CI_APP_PRIVATE_KEY (CI_KEY_PKCS8)
// The caller cannot choose another target, and no other file reads
// CI_KEY_PKCS8. Because the Apps have no secrets permission, this uses the
// caller's own GitHub authority (X-GitHub-Token, which must belong to the
// owner). The broker reads the repo public key itself; a public key from the
// caller is never used. The token, key and sealed value are never stored or
// returned.

import { gh } from "./github.js";
import { seal } from "./seal.js";

function targetFor(env, key) {
  if (key === "claude") {
    return { app: "actions", secret: "CLAUDE_APP_PRIVATE_KEY", pem: env.CLAUDE_KEY_PKCS8 };
  }
  if (key === "ci") {
    return { app: "dependabot", secret: "CI_APP_PRIVATE_KEY", pem: env.CI_KEY_PKCS8 };
  }
  return null;
}

function err(status, code) {
  return [status, { error: code }];
}

export async function secrets(env, deps, p, row, request, { checkRepo }) {
  const target = targetFor(env, p.key);
  if (!target) return err(400, "bad_key");
  row.agent = p.key;
  row.paths = target.app;

  const repo = checkRepo(env, p.repo, row);
  if (repo.error) return repo.error;
  const ghToken = (request.headers.get("X-GitHub-Token") || "").trim();
  if (!/^\S{20,255}$/.test(ghToken)) return err(400, "no_github_token");
  if (typeof target.pem !== "string" || target.pem.trim().length === 0) return err(500, "missing_key");

  // The token must be the owner's, so the broker never writes with someone
  // else's authority.
  const auth = `Bearer ${ghToken}`;
  const me = await gh(deps.fetch, "/user", { auth });
  if (me.status === 401) return err(401, "bad_github_token");
  if (me.status !== 200 || me.data?.id === undefined) return err(502, "github_error");
  if (String(me.data.id) !== String(env.OWNER_ID)) return err(403, "github_token_not_owner");

  const r = `/repos/${env.OWNER_LOGIN}/${repo.name}`;
  const pk = await gh(deps.fetch, `${r}/${target.app}/secrets/public-key`, { auth });
  if (pk.status === 403) return err(403, "github_denied");
  if (pk.status === 404) return err(404, "not_found");
  if (pk.status !== 200 || typeof pk.data?.key !== "string" || !pk.data?.key_id) return err(502, "github_error");
  let encrypted;
  try {
    encrypted = seal(target.pem, pk.data.key);
  } catch {
    return err(502, "github_error");
  }
  const put = await gh(deps.fetch, `${r}/${target.app}/secrets/${target.secret}`, {
    auth,
    method: "PUT",
    body: { encrypted_value: encrypted, key_id: pk.data.key_id },
  });
  if (put.status === 403) return err(403, "github_denied");
  if (put.status !== 201 && put.status !== 204) return err(502, "github_error");
  return [200, { key: p.key, app: target.app, secret: target.secret }];
}
