import { cleanEnv, str, port } from 'envalid';
import dotenv from 'dotenv';

dotenv.config();

/** Loads and validates API environment variables. */
const rawEnv = cleanEnv(process.env, {
  BACKEND_HOST: str({ default: '0.0.0.0' }),
  BACKEND_PORT: port({ default: 8080 }),

  DATABASE_URI: str({
    desc: 'PostgreSQL connection string',
    example: 'postgres://user:password@postgres-service:5432/notesdb',
  }),
});

export const env = rawEnv;