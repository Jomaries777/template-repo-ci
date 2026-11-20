import { describe, expect, it } from "vitest";
import worker from "../src/worker.js";

async function get(path: string, env = {}, method = "GET") {
  const res = await worker.fetch(
    new Request(`https://app.example.workers.dev${path}`, { method }),
    env,
  );
  return {
    status: res.status,
    type: res.headers.get("content-type"),
    body: await res.json(),
  };
}

describe("worker", () => {
  it("answers / like the server", async () => {
    expect(await get("/")).toEqual({
      status: 200,
      type: "application/json; charset=utf-8",
      body: { message: "hello" },
    });
  });

  it("reports the version from its bindings on /health", async () => {
    const res = await get("/health", { APP_VERSION: "abc1234" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok", version: "abc1234" });
  });

  it("falls back to dev without a version binding", async () => {
    expect((await get("/health")).body.version).toBe("dev");
  });

  it("returns a JSON 404 for unknown paths and methods", async () => {
    expect(await get("/nope")).toMatchObject({
      status: 404,
      body: { error: "not found" },
    });
    expect((await get("/", {}, "POST")).status).toBe(404);
  });
});
