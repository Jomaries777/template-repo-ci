// Cloudflare Workers entry point (deploy target cloudflare-workers, node
// stack only). It answers with the same route() as the HTTP server, so the
// smoke and acceptance suites hold for both. wrangler bundles this file
// directly; `npm run build` compiles it too, which keeps it type-checked.
import { route } from "./routes.js";

export interface Env {
  // Set per version by the adapter (`wrangler versions upload --var`).
  APP_VERSION?: string;
}

export async function handle(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const { status, body } = route(
    request.method,
    pathname,
    env.APP_VERSION ?? "dev",
  );
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export default {
  fetch: (request: Request, env: Env): Promise<Response> =>
    handle(request, env),
};
