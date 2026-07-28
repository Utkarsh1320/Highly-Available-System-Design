const state = {
  requestCount: 0,
  startTime: Date.now(),
};

function requestCounter(req, res, next) {
  state.requestCount += 1;
  next();
}

function metricsHandler(req, res) {
  const uptimeSeconds = Math.floor((Date.now() - state.startTime) / 1000);
  res
    .type("text/plain")
    .send(
      [
        `app_uptime_seconds ${uptimeSeconds}`,
        `app_requests_total ${state.requestCount}`,
      ].join("\n") + "\n"
    );
}

module.exports = { requestCounter, metricsHandler };
