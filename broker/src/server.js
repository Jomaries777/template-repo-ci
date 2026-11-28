// Cloud Run entry point, replaces the Workers entry index.js (spec 0004 Design, Runtime).

import http from "node:http";
import { Writable } from "node:stream";
import { pathToFileURL } from "node:url";

export function buildEnv(source = process.env) {
  return { ...source };
}

// bodyStream: the Node request as a WHATWG stream. Cancelling it (readJson
// does, past its byte cap) discards the rest of the body instead of
// destroying the socket, so the client still gets the 413 answer.
function bodyStream(req) {
  let open = true;
  return new ReadableStream(
    {
      start(controller) {
        req.on("data", (chunk) => {
          if (!open) return;
          controller.enqueue(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
          if (controller.desiredSize <= 0) req.pause();
        });
        req.on("end", () => {
          if (open) controller.close();
          open = false;
        });
        req.on("error", (err) => {
          if (open) controller.error(err);
          open = false;
        });
      },
      pull() {
        req.resume();
      },
      cancel() {
        open = false;
        req.resume();
      },
    },
    { highWaterMark: 64 * 1024, size: (chunk) => chunk.byteLength },
  );
}

function toRequest(req) {
  const method = req.method || "GET";
  const rawHost = req.headers.host;
  const host = (Array.isArray(rawHost) ? rawHost[0] : rawHost) || "localhost";
  const url = `http://${host}${req.url || "/"}`;

  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (value === undefined) continue;
    headers.set(key, Array.isArray(value) ? value.join(", ") : value);
  }

  const upper = method.toUpperCase();
  const init = { method, headers };
  if (upper !== "GET" && upper !== "HEAD") {
    init.body = bodyStream(req);
    init.duplex = "half";
  }
  return new Request(url, init);
}

async function writeResponse(req, res, response) {
  res.statusCode = response.status;
  for (const [key, value] of response.headers) {
    if (key === "set-cookie") continue;
    res.setHeader(key, value);
  }
  const cookies = response.headers.getSetCookie?.() ?? [];
  if (cookies.length > 0) res.setHeader("set-cookie", cookies);

  // A body the handler didn't read (a 413, say) is discarded, not reset.
  if (!req.complete) req.resume();

  if (response.body) {
    await response.body.pipeTo(Writable.toWeb(res));
  } else {
    res.end();
  }
}

export function createServer(handle, env, deps) {
  return http.createServer(async (req, res) => {
    try {
      const request = toRequest(req);
      const response = await handle(request, env, deps);
      await writeResponse(req, res, response);
    } catch {
      if (!res.headersSent) {
        if (!req.complete) req.resume();
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "internal" }));
      } else if (!res.writableEnded) {
        res.end();
      }
    }
  });
}

async function main() {
  const env = buildEnv(process.env);
  const deps = {
    fetch: (...a) => fetch(...a),
    now: () => Date.now(),
    random: () => Math.random(),
  };
  try {
    const m = await import("./firestore.js");
    if (typeof m.createAuditStore === "function") deps.audit = m.createAuditStore(env, deps);
  } catch {
    // firestore.js arrives in M1 task 1a
  }
  const { handle } = await import("./handler.js");
  const port = Number(process.env.PORT) || 8080;
  const server = createServer(handle, env, deps);
  server.listen(port, () => {
    console.log(`listening on ${port}`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
