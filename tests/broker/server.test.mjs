// Tests for broker/src/server.js (spec 0004 Design, Runtime; criterion 8).
// Offline: every server binds to 127.0.0.1 on port 0 and closes after the test.
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { buildEnv, createServer, loadAuditStore } from "../../broker/src/server.js";
import { handle as realHandle, readJson } from "../../broker/src/handler.js";
import { RELAY_MAX_BODY } from "../../broker/src/relay.js";

// Start a server on 127.0.0.1:0, run fn({ baseUrl, port }), and always close it.
async function withServer(handle, env, deps, fn) {
  const server = createServer(handle, env, deps);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const { port } = server.address();
  try {
    return await fn({ port, baseUrl: `http://127.0.0.1:${port}` });
  } finally {
    // Every assertion has run: drop all sockets, busy ones too. A fetch whose
    // upload was cut short by a 413 leaves a request the server never sees end,
    // and server.close() would wait about 5 s for it to time out.
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

// Send an HTTP/1.1 request with Transfer-Encoding: chunked (no Content-Length)
// across multiple writes and resolve with { status, headers, text }.
function sendChunked(port, path, chunks, headers = {}) {
  return new Promise((resolve, reject) => {
    let responded = false;
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        path,
        method: "POST",
        agent: false,
        headers: {
          "Content-Type": "application/json",
          "Transfer-Encoding": "chunked",
          ...headers,
        },
      },
      (res) => {
        responded = true;
        const parts = [];
        res.on("data", (d) => parts.push(d));
        res.on("end", () => {
          resolve({
            status: res.statusCode,
            headers: res.headers,
            text: Buffer.concat(parts).toString("utf8"),
          });
        });
        res.on("error", reject);
      },
    );

    req.on("error", (err) => {
      // If the server rejected an oversized stream early and closed the socket
      // after sending 413, ignore the write-side reset once the response arrived.
      if (responded) return;
      reject(err);
    });

    (async () => {
      for (const chunk of chunks) {
        if (responded || req.destroyed) break;
        if (!req.write(chunk)) {
          await new Promise((r) => req.once("drain", r));
        }
      }
      if (!responded && !req.destroyed) req.end();
    })();
  });
}

test("forwards method, pathname, and auth/forwarding headers unchanged", async () => {
  const stub = async (request) => {
    const url = new URL(request.url);
    return new Response(
      JSON.stringify({
        method: request.method,
        pathname: url.pathname,
        authorization: request.headers.get("Authorization"),
        githubToken: request.headers.get("X-GitHub-Token"),
        forwardedFor: request.headers.get("X-Forwarded-For"),
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };

  await withServer(stub, {}, {}, async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/secrets?check=1`, {
      method: "POST",
      headers: {
        Authorization: "Bearer dummy-123",
        "X-GitHub-Token": "dummy-456",
        "X-Forwarded-For": "1.2.3.4, 5.6.7.8",
      },
      body: "{}",
    });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), {
      method: "POST",
      pathname: "/secrets",
      authorization: "Bearer dummy-123",
      githubToken: "dummy-456",
      forwardedFor: "1.2.3.4, 5.6.7.8",
    });
  });
});

test("passes request.body as a ReadableStream for POST and null for GET", async () => {
  const seen = [];
  const stub = async (request) => {
    seen.push({
      method: request.method,
      isStream: request.body instanceof ReadableStream,
      isNull: request.body === null,
    });
    const text = request.body ? await request.text() : null;
    return new Response(JSON.stringify({ text }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  await withServer(stub, {}, {}, async ({ baseUrl }) => {
    const postRes = await fetch(`${baseUrl}/token`, {
      method: "POST",
      body: "hello",
    });
    assert.equal(postRes.status, 200);
    assert.deepEqual(await postRes.json(), { text: "hello" });

    const getRes = await fetch(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(getRes.status, 200);
    assert.deepEqual(await getRes.json(), { text: null });

    assert.deepEqual(seen, [
      { method: "POST", isStream: true, isNull: false },
      { method: "GET", isStream: false, isNull: true },
    ]);
  });
});

test("round-trips status code, custom response headers, and JSON body", async () => {
  const stub = async () =>
    new Response(JSON.stringify({ teapot: true }), {
      status: 418,
      headers: {
        "Content-Type": "application/json",
        "x-test": "custom-value",
        "Cache-Control": "no-store",
      },
    });

  await withServer(stub, {}, {}, async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/brew`);
    assert.equal(res.status, 418);
    assert.equal(res.headers.get("x-test"), "custom-value");
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.deepEqual(await res.json(), { teapot: true });
  });
});

test("a handle that throws gives 500 internal without leaking stack traces", async () => {
  const secretMessage = "secret-boom-details";
  const asyncStub = async () => {
    throw new Error(secretMessage);
  };
  const syncStub = () => {
    throw new Error(secretMessage);
  };

  for (const stub of [asyncStub, syncStub]) {
    await withServer(stub, {}, {}, async ({ baseUrl }) => {
      const res = await fetch(`${baseUrl}/boom`, {
        headers: { Authorization: "Bearer never-leak-this" },
      });
      assert.equal(res.status, 500);
      assert.equal(res.headers.get("content-type"), "application/json");
      const text = await res.text();
      assert.ok(!text.includes(secretMessage), "no error message leaked");
      assert.ok(!text.includes("never-leak-this"), "no request header leaked");
      assert.deepEqual(JSON.parse(text), { error: "internal" });
    });
  }
});

test("real handler GET /healthz gives 200 ok enabled", async () => {
  const env = { BROKER_ENABLED: "true" };
  const deps = { fetch: () => { throw new Error("unexpected fetch"); }, now: () => 0, random: () => 0.5 };

  await withServer(realHandle, env, deps, async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/healthz`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.deepEqual(await res.json(), { ok: true, enabled: true });
  });
});

test("real readJson enforces 1 KB and 1 MB caps with Content-Length and chunked transfer", async () => {
  const stub = async (request) => {
    const url = new URL(request.url);
    const parsed = url.pathname === "/relay"
      ? await readJson(request, RELAY_MAX_BODY)
      : await readJson(request);
    if (parsed.error) {
      return new Response(JSON.stringify({ error: parsed.error[1] }), {
        status: parsed.error[0],
        headers: { "Content-Type": "application/json" },
      });
    }
    return new Response(JSON.stringify({ parsed: parsed.value }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  await withServer(stub, {}, {}, async ({ port, baseUrl }) => {
    // 1. Small valid JSON parses (with Content-Length and chunked).
    const okRes = await fetch(`${baseUrl}/token`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ repo: "Jomaries777/demo", agent: "claude" }),
    });
    assert.equal(okRes.status, 200);
    assert.deepEqual(await okRes.json(), {
      parsed: { repo: "Jomaries777/demo", agent: "claude" },
    });

    const okChunked = await sendChunked(port, "/token", ['{"repo":"Jomaries777/', 'demo","agent":"agy"}']);
    assert.equal(okChunked.status, 200);
    assert.deepEqual(JSON.parse(okChunked.text), {
      parsed: { repo: "Jomaries777/demo", agent: "agy" },
    });

    // 2. 1025-byte body to /token gives 413 too_large with Content-Length.
    const over1k = "x".repeat(1025);
    assert.equal(Buffer.byteLength(over1k), 1025);
    const cl1k = await fetch(`${baseUrl}/token`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: over1k,
    });
    assert.equal(cl1k.status, 413);
    assert.deepEqual(await cl1k.json(), { error: "too_large" });

    // 3. 1025-byte body to /token gives 413 too_large when sent chunked (no Content-Length).
    const chunked1k = await sendChunked(port, "/token", [
      "a".repeat(300),
      "b".repeat(300),
      "c".repeat(300),
      "d".repeat(125),
    ]);
    assert.equal(chunked1k.status, 413);
    assert.deepEqual(JSON.parse(chunked1k.text), { error: "too_large" });

    // 4. Body over 1 MB (RELAY_MAX_BODY + 1) to /relay gives 413 too_large with Content-Length.
    const over1m = "y".repeat(RELAY_MAX_BODY + 1);
    assert.equal(Buffer.byteLength(over1m), RELAY_MAX_BODY + 1);
    const cl1m = await fetch(`${baseUrl}/relay`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: over1m,
    });
    assert.equal(cl1m.status, 413);
    assert.deepEqual(await cl1m.json(), { error: "too_large" });

    // 5. Body over 1 MB to /relay gives 413 too_large when sent chunked (no Content-Length).
    const chunkSize = 256 * 1024;
    const relayChunks = [
      "z".repeat(chunkSize),
      "z".repeat(chunkSize),
      "z".repeat(chunkSize),
      "z".repeat(chunkSize),
      "z",
    ];
    assert.equal(relayChunks.reduce((n, c) => n + c.length, 0), RELAY_MAX_BODY + 1);
    const chunked1m = await sendChunked(port, "/relay", relayChunks);
    assert.equal(chunked1m.status, 413);
    assert.deepEqual(JSON.parse(chunked1m.text), { error: "too_large" });
  });
});

test("buildEnv returns a plain copy without mutating the source", () => {
  const source = { BROKER_ENABLED: "true", OWNER_LOGIN: "Jomaries777" };
  const copy = buildEnv(source);
  assert.deepEqual(copy, source);
  assert.notEqual(copy, source);
  assert.equal(Object.getPrototypeOf(copy), Object.prototype);

  copy.BROKER_ENABLED = "false";
  copy.EXTRA = "added";
  assert.equal(source.BROKER_ENABLED, "true");
  assert.equal("EXTRA" in source, false);

  source.OWNER_LOGIN = "changed";
  assert.equal(copy.OWNER_LOGIN, "Jomaries777");
});

// loadAuditStore (review of #111): only a missing firestore.js itself is
// tolerated; any other failure stops the server instead of starting it
// without an audit store.
const firestoreUrl = new URL("../../broker/src/firestore.js", import.meta.url);
function notFound(path) {
  const err = new Error(`Cannot find module '${path}' imported from /app/src/server.js`);
  err.code = "ERR_MODULE_NOT_FOUND";
  return err;
}

test("loadAuditStore: a store module that loads gives its store", async () => {
  const store = { ready: async () => true };
  const got = await loadAuditStore({ A: "1" }, { x: 1 }, async () => ({
    createAuditStore: (env, deps) => {
      assert.equal(env.A, "1");
      assert.equal(deps.x, 1);
      return store;
    },
  }));
  assert.equal(got, store);
});

test("loadAuditStore: a missing firestore.js gives no store", async () => {
  const got = await loadAuditStore({}, {}, async () => {
    throw notFound(firestoreUrl.pathname);
  });
  assert.equal(got, undefined);
});

test("loadAuditStore: other failures throw", async () => {
  const cases = [
    async () => {
      throw new SyntaxError("Unexpected token");
    },
    async () => {
      throw notFound("/app/node_modules/some-dependency/index.js");
    },
    async () => ({}),
    async () => ({
      createAuditStore: () => {
        throw new Error("bad config");
      },
    }),
  ];
  for (const importer of cases) {
    await assert.rejects(loadAuditStore({}, {}, importer));
  }
});

test("a client that aborts mid-body doesn't crash the server", async () => {
  const stub = async (request) => {
    await request.text();
    return new Response("{}", { status: 200 });
  };
  await withServer(stub, {}, {}, async ({ port, baseUrl }) => {
    await new Promise((resolve) => {
      const sock = net.connect(port, "127.0.0.1", () => {
        sock.write("POST /token HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n0123456789");
        setTimeout(() => {
          sock.destroy();
          resolve();
        }, 50);
      });
      sock.on("error", () => {});
    });
    // The server still answers the next request.
    const res = await fetch(`${baseUrl}/healthz`);
    assert.equal(res.status, 200);
  });
});
