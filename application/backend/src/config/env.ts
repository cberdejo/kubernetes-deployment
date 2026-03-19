import { cleanEnv, str, port } from 'envalid';
import dotenv from 'dotenv';

dotenv.config();

/**
 * Carga y valida variables de entorno de la API.
 *
 * Si `DATABASE_URI` no está definida, se construye a partir de:
 * - POSTGRES_USER
 * - POSTGRES_PASSWORD
 * - POSTGRES_DB
 */
const rawEnv = cleanEnv(process.env, {
  BACKEND_HOST: str({ default: '0.0.0.0' }),
  BACKEND_PORT: port({ default: 8080 }),

  POSTGRES_USER: str({ default: 'postgres' }),
  POSTGRES_PASSWORD: str({ default: 'postgres' }),
  POSTGRES_HOST: str({ default: 'localhost' }),
  POSTGRES_PORT: port({ default: 5432 }),
  POSTGRES_DB: str({ default: 'notesdb' }),

  DATABASE_URI: str({
    desc: 'Connection string de PostgreSQL',
    example: 'postgres://user:password@postgres-service:5432/notesdb',
    default: '',
  }),
});

export const env = {
  ...rawEnv,
  DATABASE_URI:
    rawEnv.DATABASE_URI ||
    `postgres://${rawEnv.POSTGRES_USER}:${rawEnv.POSTGRES_PASSWORD}@${rawEnv.POSTGRES_HOST}:${rawEnv.POSTGRES_PORT}/${rawEnv.POSTGRES_DB}`,
};