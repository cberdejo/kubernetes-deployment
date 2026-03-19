import { DataSource } from "typeorm";
import { Note } from "../entities/Note";
import { env } from "./env";

// Configure the main data source for PostgreSQL using environment variables
export const AppDataSource = new DataSource({
    type: "postgres",
    url: env.DATABASE_URI,
    synchronize: true,
    logging: false,
    entities: [Note],
});

// Initializes the database connection
export const initializeDatabase = async () => {
    try {
        await AppDataSource.initialize();
        console.log("PostgreSQL database connected");
    } catch (error) {
        console.error("Error connecting to the database:", error);
        process.exit(1);
    }
};