const express = require("express");
const logger = require("./logger");
const { requestCounter, metricsHandler } = require("./metrics");

const app = express();
const PORT = process.env.PORT || 3000;

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

app.listen(PORT, () => {
  logger.info(`Server listening on port ${PORT}`);

  // simulate app warm-up before it becomes ready to serve traffic
  setTimeout(() => {
    isReady = true;
    logger.info("Server is now ready");
  }, 3000);
});
