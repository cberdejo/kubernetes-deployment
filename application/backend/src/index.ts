import "reflect-metadata";
import express from "express";
import { env } from "./config/env";
import { initializeDatabase } from "./config/database";
import noteRoutes from "./routes/note.routes";
import { observeRequests, registry } from "./config/metrics";
import cors from "cors";

const app = express();

app.use(
  cors({
    origin: '*',
    methods: ['GET', 'POST', 'PUT', 'DELETE'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  })
);
app.use(observeRequests);
app.use(express.json());
app.use("/api/v1", noteRoutes);

// Scraped by Prometheus inside the cluster. The frontend only proxies
// /api/v1*, so this endpoint is not reachable from todo.local.
app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", registry.contentType);
  res.send(await registry.metrics());
});

const startServer = async () => {
  await initializeDatabase();

  app.listen(env.BACKEND_PORT, env.BACKEND_HOST, () => {
    console.log(`Server running at http://${env.BACKEND_HOST}:${env.BACKEND_PORT}`);
    // Never log DATABASE_URI itself: it contains the password, and every log
    // line ends up in Loki, readable by anyone with access to Grafana.
    const db = new URL(env.DATABASE_URI);
    console.log(`Connected to ${db.hostname}:${db.port || "5432"}${db.pathname}`);
  });
};

startServer();