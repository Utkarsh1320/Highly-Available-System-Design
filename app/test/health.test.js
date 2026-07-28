const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const express = require("express");
const { requestCounter, metricsHandler } = require("../src/metrics");

function buildApp() {
  const app = express();
  let isReady = false;

  app.use(requestCounter);

  app.get("/healthz", (req, res) => {
    res.status(200).json({ status: "ok" });
  });

  app.get("/readyz", (req, res) => {
    if (isReady) {
      res.status(200).json({ status: "ready" });
    } else {
      res.status(503).json({ status: "not ready" });
    }
  });

  app.get("/metrics", metricsHandler);

  return { app, setReady: (value) => (isReady = value) };
}

function withServer(app, fn) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(app);
    server.listen(0, async () => {
      const { port } = server.address();
      try {
        await fn(`http://127.0.0.1:${port}`);
        resolve();
      } catch (err) {
        reject(err);
      } finally {
        server.close();
      }
    });
  });
}

test("GET /healthz returns 200 ok", async () => {
  const { app } = buildApp();
  await withServer(app, async (baseUrl) => {
    const res = await fetch(`${baseUrl}/healthz`);
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.deepEqual(body, { status: "ok" });
  });
});

test("GET /readyz returns 503 before the app is ready", async () => {
  const { app } = buildApp();
  await withServer(app, async (baseUrl) => {
    const res = await fetch(`${baseUrl}/readyz`);
    const body = await res.json();
    assert.equal(res.status, 503);
    assert.deepEqual(body, { status: "not ready" });
  });
});

test("GET /readyz returns 200 once the app is marked ready", async () => {
  const { app, setReady } = buildApp();
  setReady(true);
  await withServer(app, async (baseUrl) => {
    const res = await fetch(`${baseUrl}/readyz`);
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.deepEqual(body, { status: "ready" });
  });
});

test("GET /metrics returns uptime and request counters", async () => {
  const { app } = buildApp();
  await withServer(app, async (baseUrl) => {
    const res = await fetch(`${baseUrl}/metrics`);
    const body = await res.text();
    assert.equal(res.status, 200);
    assert.match(body, /app_uptime_seconds \d+/);
    assert.match(body, /app_requests_total \d+/);
  });
});
