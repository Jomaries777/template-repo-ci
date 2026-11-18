import {
  createServer as createHttpServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import { route } from "./routes.js";

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

    const { status, body } = route(req.method, pathname);
    sendJson(res, status, body);
  });
}

export function resolvePort(
  raw: string | undefined = process.env.PORT,
): number {
  if (!raw || raw.trim() === "") {
    return 8080;
  }
  const parsed = Number(raw);
  // 0 (a random port) would break the fixed 8080 in Dockerfile and compose.
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
    throw new RangeError(`Invalid PORT: ${raw}`);
  }
  return parsed;
}

// Cloud Run sends SIGKILL 10 s after SIGTERM; exit cleanly before that.
const SHUTDOWN_TIMEOUT_MS = 8000;

export function startServer(port: number = resolvePort()): Server {
  const server = createServer();
  const onSigterm = (): void => {
    console.log("SIGTERM: closing server");
    server.close();
    server.closeIdleConnections();
    // A stuck connection must not hang shutdown. unref() keeps the timer
    // from holding the process open once the server has closed.
    setTimeout(() => {
      console.error("SIGTERM: connections still open, forcing exit");
      process.exit(1);
    }, SHUTDOWN_TIMEOUT_MS).unref();
  };
  process.on("SIGTERM", onSigterm);
  server.on("close", () => {
    process.off("SIGTERM", onSigterm);
  });
  server.listen(port);
  return server;
}
