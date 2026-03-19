import "reflect-metadata"; 
import express from "express";
import { env } from "./config/env";
import { initializeDatabase } from "./config/database";
import noteRoutes from "./routes/note.routes";
import cors from "cors";

const app = express();
app.use(
  cors({
    origin: '*',
    methods: ['GET', 'POST', 'PUT', 'DELETE'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  })
);
app.use(express.json());
app.use("/api/v1", noteRoutes);

const startServer = async () => {
    await initializeDatabase();

    app.listen(env.BACKEND_PORT, env.BACKEND_HOST, () => {
        console.log(`Servidor corriendo en http://${env.BACKEND_HOST}:${env.BACKEND_PORT}`);
        console.log(`Conectado a ${env.DATABASE_URI}`);
    });
};

startServer();