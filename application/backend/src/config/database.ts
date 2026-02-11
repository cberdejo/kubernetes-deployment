import { DataSource } from "typeorm";
import { Note } from "../entities/Note";
import { env } from "./env";

export const AppDataSource = new DataSource({
    type: "postgres",
    url: env.DATABASE_URI, 
    synchronize: true,     
    logging: false,
    entities: [Note],
});

export const initializeDatabase = async () => {
    try {
        await AppDataSource.initialize();
        console.log("📦 Base de datos PostgreSQL conectada");
    } catch (error) {
        console.error("Error conectando a la base de datos:", error);
        process.exit(1);
    }
};