// Minimal GitHub REST helper for the broker.

const API = "https://api.github.com";

// gh(fetchFn, path, { auth, method, body, timeoutMs }): JSON call to the GitHub
// API. `auth` is the full Authorization value ("Bearer …"). Returns
// { status, data }; data is null when the body isn't JSON.
export async function gh(fetchFn, path, { auth, method = "GET", body, timeoutMs = 5000 } = {}) {
  const headers = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "agent-bot-broker",
  };
  if (auth) headers.Authorization = auth;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetchFn(`${API}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  let data = null;
  try {
    data = await res.json();
  } catch {
    data = null;
  }
  return { status: res.status, data };
}
