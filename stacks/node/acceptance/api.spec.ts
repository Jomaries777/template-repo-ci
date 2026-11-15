import { expect, test } from "@playwright/test";

test("GET /healthz returns ok @prod-safe", async ({ request }) => {
  const res = await request.get("/healthz");
  expect(res.status()).toBe(200);
  const body = (await res.json()) as { status: string; version: string };
  expect(body.status).toBe("ok");
  expect(typeof body.version).toBe("string");
  expect(body.version.length).toBeGreaterThan(0);
});

test("GET / returns hello @prod-safe", async ({ request }) => {
  const res = await request.get("/");
  expect(res.status()).toBe(200);
  expect(await res.json()).toEqual({ message: "hello" });
});

test("GET /unknown returns 404 JSON", async ({ request }) => {
  const res = await request.get("/unknown");
  expect(res.status()).toBe(404);
  expect(await res.json()).toEqual({ error: "not found" });
});
