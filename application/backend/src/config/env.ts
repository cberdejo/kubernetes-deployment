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
  POSTGRES_DB: str({ default: 'notesdb' }),

  // Opcional: si se define, tendrá prioridad sobre la URL construida
  DATABASE_URI: str({
    desc: 'Connection string de PostgreSQL',
    example: 'postgres://user:password@localhost:5432/notesdb',
    default: '',
  }),
});

export const env = {
  ...rawEnv,
  DATABASE_URI:
    rawEnv.DATABASE_URI ||
    `postgres://${rawEnv.POSTGRES_USER}:${rawEnv.POSTGRES_PASSWORD}@localhost:5432/${rawEnv.POSTGRES_DB}`,
};