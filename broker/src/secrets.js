// POST /secrets (spec 0002 FR-8, C4): set the bot App key as the repo secret
// BOT_APP_PRIVATE_KEY (Actions and/or Dependabot) without the key ever
// leaving the broker. The bot App has no secrets permission (NFR-4), so this
// uses the caller's own GitHub authority: X-GitHub-Token, which must belong
// to the owner. The broker reads each repo public key itself; a public key
// from the caller is never used, so the key can't be sealed to anyone else.
// The token, the key and the sealed value are never stored or returned.

import { gh } from "./github.js";
import { seal } from "./seal.js";

const APPS = new Set(["actions", "dependabot"]);
const SECRET = "BOT_APP_PRIVATE_KEY";

function err(status, code, set) {
  return [status, set && set.length ? { error: code, set } : { error: code }];
}

export async function secrets(env, deps, p, row, request, { checkRepo }) {
  const repo = checkRepo(env, p.repo, row);
  if (repo.error) return repo.error;
  const apps = p.apps;
  if (!Array.isArray(apps) || apps.length === 0 || apps.length > 2 || new Set(apps).size !== apps.length) {
    return err(400, "bad_apps");
  }
  if (!apps.every((a) => APPS.has(a))) return err(400, "bad_apps");
  row.paths = apps.join(",");
  const ghToken = (request.headers.get("X-GitHub-Token") || "").trim();
  if (!/^\S{20,255}$/.test(ghToken)) return err(400, "no_github_token");

  // The token must be the owner's, so the broker never writes with someone
  // else's authority.
  const auth = `Bearer ${ghToken}`;
  const me = await gh(deps.fetch, "/user", { auth });
  if (me.status === 401) return err(401, "bad_github_token");
  if (me.status !== 200 || me.data?.id === undefined) return err(502, "github_error");
  if (String(me.data.id) !== String(env.OWNER_ID)) return err(403, "github_token_not_owner");

  const r = `/repos/${env.OWNER_LOGIN}/${repo.name}`;
  const set = [];
  for (const app of apps) {
    const pk = await gh(deps.fetch, `${r}/${app}/secrets/public-key`, { auth });
    // Errors after the first app name the apps already set, so a rotation
    // never leaves the caller unaware that the two secrets now differ.
    if (pk.status === 403) return err(403, "github_denied", set);
    if (pk.status === 404) return err(404, "not_found", set);
    if (pk.status !== 200 || typeof pk.data?.key !== "string" || !pk.data?.key_id) return err(502, "github_error", set);
    let encrypted;
    try {
      encrypted = seal(env.APP_KEY_PKCS8, pk.data.key);
    } catch {
      return err(502, "github_error", set);
    }
    const put = await gh(deps.fetch, `${r}/${app}/secrets/${SECRET}`, {
      auth,
      method: "PUT",
      body: { encrypted_value: encrypted, key_id: pk.data.key_id },
    });
    if (put.status === 403) return err(403, "github_denied", set);
    if (put.status !== 201 && put.status !== 204) return err(502, "github_error", set);
    set.push(app);
  }
  return [200, { set }];
}
