const express = require("express");
const logger = require("./logger");
const { requestCounter, metricsHandler } = require("./metrics");

const app = express();
const PORT = process.env.PORT || 3000;

let isReady = false;

app.use(requestCounter);

app.use((req, res, next) => {
  const startedAt = process.hrtime.bigint();
  res.on("finish", () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    const level = res.statusCode >= 500 ? "error" : res.statusCode >= 400 ? "warn" : "info";
    logger[level]("request", {
      method: req.method,
      path: req.originalUrl,
      status: res.statusCode,
      durationMs: Math.round(durationMs * 100) / 100,
    });
  });
  next();
});

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

app.listen(PORT, () => {
  logger.info(`Server listening on port ${PORT}`);

  // simulate app warm-up before it becomes ready to serve traffic
  setTimeout(() => {
    isReady = true;
    logger.info("Server is now ready");
  }, 3000);
});
