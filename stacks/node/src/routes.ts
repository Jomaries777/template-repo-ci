// The service's routes as one pure function, shared by the HTTP server and
// the static export (`make build-static`), so both always answer the same.
export interface Response {
  status: number;
  body: Record<string, unknown>;
}

// `version` defaults to APP_VERSION from the process environment. The
// Cloudflare Worker (worker.ts) passes it from its bindings instead: Workers
// have no `process` unless nodejs_compat is on.
export function route(
  method: string | undefined,
  path: string,
  version: string = process.env.APP_VERSION ?? "dev",
): Response {
  if (method === "GET" && path === "/") {
    return { status: 200, body: { message: "hello" } };
  }
  // Not /healthz: Cloud Run reserves some paths that end in "z".
  if (method === "GET" && path === "/health") {
    return { status: 200, body: { status: "ok", version } };
  }
  return { status: 404, body: { error: "not found" } };
}

// GET routes that `make build-static` renders to files for static hosts.
export const STATIC_ROUTES = ["/", "/health"] as const;
