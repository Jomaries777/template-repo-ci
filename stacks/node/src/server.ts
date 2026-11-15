import {
  createServer as createHttpServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";

function sendJson(
  res: ServerResponse,
  statusCode: number,
  body: Record<string, unknown>,
): void {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload).toString(),
  });
  res.end(payload);
}

export function createServer(): Server {
  return createHttpServer((req: IncomingMessage, res: ServerResponse) => {
    const pathname = new URL(req.url ?? "/", "http://localhost").pathname;

    if (req.method === "GET" && pathname === "/") {
      sendJson(res, 200, { message: "hello" });
      return;
    }

    if (req.method === "GET" && pathname === "/healthz") {
      sendJson(res, 200, {
        status: "ok",
        version: process.env.APP_VERSION ?? "dev",
      });
      return;
    }

    sendJson(res, 404, { error: "not found" });
  });
}

export function resolvePort(
  raw: string | undefined = process.env.PORT,
): number {
  if (!raw || raw.trim() === "") {
    return 8080;
  }
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) {
    throw new RangeError(`Invalid PORT: ${raw}`);
  }
  return parsed;
}

export function startServer(port: number = resolvePort()): Server {
  const server = createServer();
  const onSigterm = (): void => {
    server.close();
  };
  process.on("SIGTERM", onSigterm);
  server.on("close", () => {
    process.off("SIGTERM", onSigterm);
  });
  server.listen(port);
  return server;
}
