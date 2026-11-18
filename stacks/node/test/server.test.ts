import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { createServer, resolvePort, startServer } from "../src/server.js";

async function listen(server: Server): Promise<string> {
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const addr = server.address() as AddressInfo;
  return `http://127.0.0.1:${addr.port}`;
}

async function close(server: Server): Promise<void> {
  if (!server.listening) {
    return;
  }
  await new Promise<void>((resolve, reject) => {
    server.close((err) => (err ? reject(err) : resolve()));
  });
}

describe("server", () => {
  const originalAppVersion = process.env.APP_VERSION;
  let activeServer: Server | undefined;

  afterEach(async () => {
    if (originalAppVersion === undefined) {
      delete process.env.APP_VERSION;
    } else {
      process.env.APP_VERSION = originalAppVersion;
    }
    if (activeServer) {
      await close(activeServer);
      activeServer = undefined;
    }
  });

  it("GET / returns 200 hello JSON", async () => {
    activeServer = createServer();
    const baseUrl = await listen(activeServer);

    const res = await fetch(`${baseUrl}/`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(await res.json()).toEqual({ message: "hello" });
  });

  it("GET /health returns default dev version when APP_VERSION is unset", async () => {
    delete process.env.APP_VERSION;
    activeServer = createServer();
    const baseUrl = await listen(activeServer);

    const res = await fetch(`${baseUrl}/health`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(await res.json()).toEqual({ status: "ok", version: "dev" });
  });

  it("GET /health returns APP_VERSION when set", async () => {
    process.env.APP_VERSION = "1.2.3-sha";
    activeServer = createServer();
    const baseUrl = await listen(activeServer);

    const res = await fetch(`${baseUrl}/health`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "ok", version: "1.2.3-sha" });
  });

  // Cloud Run reserves some paths ending in "z" (its front end answers 404
  // before the app sees them), so the health route must not be /healthz.
  it("does not serve /healthz (reserved on Cloud Run)", async () => {
    activeServer = createServer();
    const baseUrl = await listen(activeServer);

    const res = await fetch(`${baseUrl}/healthz`);
    expect(res.status).toBe(404);
  });

  it("returns 404 JSON for unknown routes and methods", async () => {
    activeServer = createServer();
    const baseUrl = await listen(activeServer);

    const getUnknown = await fetch(`${baseUrl}/missing`);
    expect(getUnknown.status).toBe(404);
    expect(getUnknown.headers.get("content-type")).toContain(
      "application/json",
    );
    expect(await getUnknown.json()).toEqual({ error: "not found" });

    const postRoot = await fetch(`${baseUrl}/`, { method: "POST" });
    expect(postRoot.status).toBe(404);
    expect(await postRoot.json()).toEqual({ error: "not found" });
  });

  it("resolves PORT and shuts down gracefully on SIGTERM", async () => {
    expect(resolvePort(undefined)).toBe(8080);
    expect(resolvePort("")).toBe(8080);
    expect(resolvePort("3000")).toBe(3000);
    expect(() => resolvePort("invalid")).toThrow(RangeError);
    expect(() => resolvePort("0")).toThrow(RangeError);

    activeServer = startServer(0);
    await new Promise<void>((resolve) => {
      if (activeServer?.listening) {
        resolve();
      } else {
        activeServer?.once("listening", () => resolve());
      }
    });
    expect(activeServer.listening).toBe(true);

    const closed = new Promise<void>((resolve) => {
      activeServer?.once("close", () => resolve());
    });
    process.emit("SIGTERM");
    await closed;
    expect(activeServer.listening).toBe(false);
  });
});
