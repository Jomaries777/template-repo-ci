// Shared fakes for the broker tests: a throwaway App key, an in-memory D1,
// a fake GitHub and request helpers. Nothing touches the network.
import { handle } from "../../broker/src/handler.js";

export const OWNER_ID = "322333432";
export const OTHER_ID = "999";
// Fake credentials, built so no literal looks like a real secret.
export const OWNER_CRED = ["owner", "identity", "cred"].join("-");
export const OTHER_CRED = ["other", "identity", "cred"].join("-");
export const INST_TOKEN = ["inst", "token", "value"].join("-");
// An owner token that the login App did not issue (gh CLI, a PAT, ...).
export const OWNER_OTHER_APP = ["owner", "gh", "cli"].join("-");
export const LOGIN_ID = "Iv23liFOZk5YaGC6CJc9";
export const LOGIN_SECRET = ["login", "client", "secret"].join("-");

// --- a throwaway App key, exported as a PKCS#8 PEM
export const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
);
const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const label = ["PRIVATE", "KEY"].join(" ");
export const pem = `-----BEGIN ${label}-----\n${Buffer.from(der).toString("base64")}\n-----END ${label}-----\n`;

// --- in-memory D1 stub for the three statements the handler uses
export function d1({ failRead = false, oldSchema = false } = {}) {
  const rows = [];
  return {
    rows,
    prepare(sql) {
      return {
        async all() {
          if (!sql.startsWith("SELECT ts, caller_id")) throw new Error(`unexpected all: ${sql}`);
          if (oldSchema) throw new Error("D1_ERROR: no such column: branch");
          return { results: [] };
        },
        bind(...args) {
          return {
            async run() {
              if (sql.startsWith("INSERT INTO audit")) {
                const [ts, caller_id, endpoint, repo, outcome, reason, expires_at, ip, branch, files, paths] = args;
                rows.push({ ts, caller_id, endpoint, repo, outcome, reason, expires_at, ip, branch, files, paths });
              } else if (sql.startsWith("DELETE FROM audit")) {
                for (let i = rows.length - 1; i >= 0; i--) if (rows[i].ts < args[0]) rows.splice(i, 1);
              } else throw new Error(`unexpected run: ${sql}`);
              return { success: true };
            },
            async first() {
              if (!sql.startsWith("SELECT COUNT(*)")) throw new Error(`unexpected first: ${sql}`);
              if (failRead) throw new Error("D1_ERROR: unavailable");
              const [caller, endpoint, since] = args;
              const n = rows.filter((r) => r.caller_id === caller && r.endpoint === endpoint && r.ts > since).length;
              return { n };
            },
          };
        },
      };
    },
  };
}

// --- fake GitHub
export // github({ installStatus, tokenStatus, routes }): routes(url, init, reply)
// answers repo API calls for the relay tests, or returns undefined.
function github({ installStatus = 200, tokenStatus = 201, routes } = {}) {
  const calls = [];
  const fetch = async (url, init = {}) => {
    const auth = init.headers?.Authorization || "";
    calls.push({ url, method: init.method || "GET", auth, body: init.body });
    const reply = (status, obj) => new Response(JSON.stringify(obj), { status });
    // "Check a token": 200 only for tokens the login App issued, with the
    // App's client credentials; 404 otherwise.
    if (url === `https://api.github.com/applications/${LOGIN_ID}/token`) {
      if (auth !== `Basic ${btoa(`${LOGIN_ID}:${LOGIN_SECRET}`)}` || init.method !== "POST") {
        return reply(401, { message: "Requires authentication" });
      }
      const t = JSON.parse(init.body).access_token;
      if (t === OWNER_CRED) return reply(200, { user: { id: Number(OWNER_ID), login: "Jomaries777" } });
      if (t === OTHER_CRED) return reply(200, { user: { id: Number(OTHER_ID), login: "someone" } });
      return reply(404, { message: "Not Found" });
    }
    if (url === "https://api.github.com/repos/Jomaries777/sandbox-node-local/installation") {
      return installStatus === 200 ? reply(200, { id: 77 }) : reply(installStatus, { message: "x" });
    }
    if (url === "https://api.github.com/app/installations/77/access_tokens") {
      return tokenStatus === 201
        ? reply(201, { token: INST_TOKEN, expires_at: "2026-11-16T17:00:00Z" })
        : reply(tokenStatus, { message: "x" });
    }
    const routed = routes?.(url, init, reply);
    if (routed) return routed;
    return reply(404, { message: "Not Found" });
  };
  return { fetch, calls };
}

export function env(over = {}) {
  return {
    OWNER_LOGIN: "Jomaries777",
    OWNER_ID,
    APP_ID: "5766032",
    APP_SLUG: "jomaries777-agent-bot",
    BROKER_ENABLED: "true",
    APP_KEY_PKCS8: pem,
    LOGIN_CLIENT_ID: LOGIN_ID,
    LOGIN_CLIENT_SECRET: LOGIN_SECRET,
    AUDIT: d1(),
    ...over,
  };
}

export const NOW = Date.UTC(2026, 10, 16, 15, 0, 0);
export function req(body, cred = OWNER_CRED, { path = "/token", method = "POST", raw, stream, extraHeaders = {} } = {}) {
  const headers = { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.9", ...extraHeaders };
  if (cred) headers.Authorization = `Bearer ${cred}`;
  if (stream) {
    // A body with no Content-Length, sent in chunks.
    const chunk = new TextEncoder().encode("x".repeat(512));
    let n = 0;
    const rs = new ReadableStream({
      pull(c) {
        if (n++ < stream) c.enqueue(chunk);
        else c.close();
      },
    });
    return new Request(`https://broker.example${path}`, { method, headers, body: rs, duplex: "half" });
  }
  return new Request(`https://broker.example${path}`, {
    method,
    headers,
    body: method === "GET" ? undefined : (raw ?? JSON.stringify(body)),
  });
}
export async function call(request, e = env(), gh = github(), random = () => 0.5) {
  const res = await handle(request, e, { fetch: gh.fetch, now: () => NOW, random });
  return { res, body: await res.json(), e, gh };
}

