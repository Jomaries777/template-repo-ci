// `node dist/export.js <dir>`: render the GET routes to static files for
// hosts that only serve files (GitHub Pages). "/" becomes index.html and
// "/health" becomes health/index.html, so the same smoke suite passes against
// the export served locally and against the live site.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { route, STATIC_ROUTES } from "./routes.js";

export function exportStatic(outDir: string): string[] {
  const written: string[] = [];
  for (const path of STATIC_ROUTES) {
    const { status, body } = route("GET", path);
    if (status !== 200) {
      throw new Error(`export: GET ${path} returned ${status}`);
    }
    const target = join(outDir, path.replace(/^\/+|\/+$/g, ""), "index.html");
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, JSON.stringify(body));
    written.push(target);
  }
  return written;
}

const [, script, outDir] = process.argv;
if (script?.endsWith("export.js")) {
  if (!outDir) {
    console.error("usage: node dist/export.js <output dir>");
    process.exit(2);
  }
  for (const file of exportStatic(outDir)) console.log(file);
}
