import type { NextFunction, Request, Response } from "express";
import client from "prom-client";

/** Prometheus metrics for the API, served on /metrics (outside /api/v1). */
export const registry = new client.Registry();

// Node.js process metrics: CPU, memory, event loop lag, GC.
client.collectDefaultMetrics({ register: registry });

const httpRequests = new client.Counter({
  name: "http_requests_total",
  help: "HTTP requests handled by the API",
  labelNames: ["method", "route", "status_code"],
  registers: [registry],
});

const httpDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [registry],
});

/**
 * Records every request as metrics and as one JSON access log line.
 *
 * The route label is the matched route pattern (/api/v1/:name), never the
 * real path: one label value per note name would create a new time series
 * for every note.
 */
export const observeRequests = (req: Request, res: Response, next: NextFunction) => {
  const end = httpDuration.startTimer();

  res.on("finish", () => {
    if (req.path === "/metrics") return;

    const route = req.route ? `${req.baseUrl}${req.route.path}` : "unmatched";
    const labels = { method: req.method, route, status_code: String(res.statusCode) };
    const seconds = end(labels);
    httpRequests.inc(labels);

    console.log(
      JSON.stringify({
        level: res.statusCode >= 500 ? "error" : "info",
        msg: "request",
        method: req.method,
        path: req.originalUrl,
        route,
        status_code: res.statusCode,
        duration_ms: Math.round(seconds * 1000),
      })
    );
  });

  next();
};
