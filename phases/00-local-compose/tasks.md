# Phase 00 - Tasks: Local Docker Compose

In this phase you will build the containerized version of the application from scratch: write the Dockerfiles, configure Docker Compose, and verify that the full stack works locally.

I recommend checking off each task as you complete it in this file.

---

## 1. Explore the Application Source

**Goal:** Understand what you need to containerize before writing any Dockerfiles.

### Steps

1. Read the backend source code in `application/backend/`:
   - Check `package.json` for the build script and dependencies.
   - Check `tsconfig.json` for the output directory.
   - Check `src/config/env.ts` for which environment variables the backend reads at runtime.

2. Read the frontend source code in `application/frontend/`:
   - Check `package.json` for the build script.
   - Check `vite.config.js` for any relevant build configuration.
   - Check `src/App.jsx` for how the frontend calls the API.

3. Identify the database requirements:
   - PostgreSQL is used. No custom image is needed, the official `postgres:15` image is sufficient.

### Questions

- What language is the backend written in, and what build step is needed?
- How does the frontend know where to send API requests?
- Which component(s) need a custom image and which can use an off-the-shelf image?

---

## 2. Write the Backend Dockerfile

**Goal:** Create a multi-stage Dockerfile for the backend.

### Steps

1. Create `application/backend/Dockerfile`.

2. Design three stages:

   **Stage 1 - Base:**
   - Use `node:20-alpine` as the base image.
   - Set the working directory to `/app`.
   - Copy `package.json` and `package-lock.json`.

   **Stage 2 - Build:**
   - Start from the base stage.
   - Install all dependencies (including dev) with `npm ci`.
   - Copy `tsconfig.json` and `src/`.
   - Run `npm run build` to compile TypeScript to JavaScript.

   **Stage 3 - Production runtime:**
   - Start fresh from `node:20-alpine` (not from the build stage).
   - Set `NODE_ENV=production`.
   - Copy `package.json` and `package-lock.json`, then run `npm ci --omit=dev`.
   - Copy the compiled output from the build stage (`dist/`).
   - Expose the backend port.
   - Set default environment variables for host and port.
   - Define the startup command.

3. Create `application/backend/.dockerignore`:
   ```
   node_modules
   dist
   .env
   *.env
   .git
   .gitignore
   Dockerfile*
   ```

4. Build and verify the image:
   ```bash
   docker build -t todo-backend:dev application/backend/
   docker images todo-backend
   ```

### Expected result

- The image builds without errors.
- The final image size is small (no dev dependencies, no TypeScript source).

### Questions

- Why do we use a separate stage for the build instead of building in the production stage?
- What would happen if we didn't have a `.dockerignore` and the host `node_modules` were copied into the image?

---

## 3. Write the Frontend Dockerfile

**Goal:** Create a multi-stage Dockerfile for the frontend with a build argument and a Caddy reverse proxy.

### Steps

1. Create `application/frontend/Dockerfile`.

2. Design two stages:

   **Stage 1 - Build:**
   - Use `node:20-alpine` as the base image.
   - Accept a build argument `VITE_API_URL` and set it as an environment variable (Vite requires `VITE_`-prefixed env vars to be present during build).
   - Copy dependency files and run `npm ci`.
   - Copy the rest of the source code.
   - Run `npm run build` to produce static files.

   **Stage 2 - Production runtime:**
   - Use `caddy:2-alpine` as the base image (not Node.js).
   - Copy the built static files from stage 1 into Caddy's serve directory (`/usr/share/caddy`).
   - Copy the `Caddyfile` into `/etc/caddy/Caddyfile`.
   - Expose port 80.
   - Start Caddy.

3. Inspect the existing `Caddyfile` in `application/frontend/`:
   ```caddyfile
   :80 {
     root * /usr/share/caddy
     encode gzip

     handle /api/v1* {
       reverse_proxy {$BACKEND_UPSTREAM}
     }

     handle {
       try_files {path} /index.html
       file_server
     }
   }
   ```

4. Create `application/frontend/.dockerignore`:
   ```
   node_modules
   dist
   .git
   .gitignore
   .env
   *.env
   Dockerfile*
   ```

5. Build and verify the image:
   ```bash
   docker build -t todo-frontend:dev --build-arg VITE_API_URL="/api/v1" application/frontend/
   docker images todo-frontend
   ```

### Expected result

- The image builds without errors.
- The final image uses Caddy (not Node.js), check with `docker inspect todo-frontend:dev | grep -i caddy`.
- The image does not contain `node_modules` or source code.

### Questions

- Why is `VITE_API_URL` a build argument instead of a runtime environment variable?
- Why does the production stage use Caddy instead of Node.js to serve the frontend?
- What does the `reverse_proxy {$BACKEND_UPSTREAM}` directive do?

---

## 4. Write the Environment File

**Goal:** Create a `.env` file that centralizes all configuration for Docker Compose.

### Steps

1. Create `phases/00-local-compose/solution/.env` based on the template:
   ```env
   POSTGRES_USER=user
   POSTGRES_PASSWORD=password
   POSTGRES_DB=data_agency_db

   BACKEND_HOST=0.0.0.0
   BACKEND_PORT=9090
   DATABASE_URI=postgres://user:password@postgres:5432/data_agency_db

   FRONTEND_HOST=localhost
   ```

2. Understand each variable:
   - `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, consumed by the official PostgreSQL image to initialize the database on first start.
   - `DATABASE_URI`, consumed by the backend to connect to PostgreSQL. Note the hostname `postgres`, this is the service name in Docker Compose.
   - `BACKEND_HOST`, `BACKEND_PORT`, the backend binds to this address and port.

### Questions

- Why should `.env` files never be committed to Git?
- What is the purpose of a `.env.template` file alongside the `.env`?

---

## 5. Write the Docker Compose File

**Goal:** Define all three services and their relationships in a single `docker-compose.yml`.

### Steps

1. Create `phases/00-local-compose/solution/docker-compose.yml`.

2. Define the **postgres** service:
   - Use `image: postgres:15`.
   - Load environment variables from `.env` with `env_file`.
   - Mount a named volume at `/var/lib/postgresql/data`.
   - Add a healthcheck using `pg_isready`.

3. Define the **backend** service:
   - Build from `../../application/backend` using its Dockerfile.
   - Load environment variables from `.env`.
   - Set the `DATABASE_URI` using variable interpolation from `.env`.
   - Use `depends_on` with `condition: service_healthy` to wait for PostgreSQL.

4. Define the **frontend** service:
   - Build from `../../application/frontend` using its Dockerfile.
   - Pass the build argument `VITE_API_URL: "/api/v1"`.
   - Set `BACKEND_UPSTREAM: backend:${BACKEND_PORT:-9090}` so Caddy knows where to proxy API calls.
   - Map port `8080:80` to expose the app on the host.
   - Depend on the backend.

5. Define the named volume:
   ```yaml
   volumes:
     postgres_data:
   ```

### Expected result

- The file has three services: `postgres`, `backend`, `frontend`.
- Only `frontend` has a `ports` mapping, backend and postgres communicate internally.
- PostgreSQL uses a named volume for data persistence.
- The startup order is: postgres → backend → frontend.

---

## 6. Build and Run the Application

**Goal:** Start the full stack and verify end-to-end connectivity.

### Steps

1. Navigate to the solution directory:
   ```bash
   cd phases/00-local-compose/solution/
   ```

2. Build and start all services:
   ```bash
   docker compose up --build
   ```

3. Wait for the health check and verify:
   - Open `http://localhost:8080` in your browser, the frontend should load.
   - Create a note through the UI.
   - Check the terminal output for backend logs confirming the database connection.

4. In a separate terminal, verify the containers:
   ```bash
   docker compose ps
   ```

### Expected result

- Three containers are running: `postgres`, `backend`, `frontend`.
- The frontend is accessible at `http://localhost:8080`.
- Notes can be created and are displayed in the UI.

---

## 7. Explore Containers

**Goal:** Inspect the running containers to understand what Docker created.

### Steps

1. List running containers:
   ```bash
   docker ps
   ```

2. Inspect the images being used:
   ```bash
   docker images | grep -E "todo|postgres"
   ```

3. Check the size difference between the build context and the final images.

4. View the logs of a specific service:
   ```bash
   docker compose logs backend
   docker compose logs postgres
   ```

### Questions

- How many containers are running?
- What are the image sizes? Is the frontend image smaller than the backend? Why or why not?
- Can you see the database connection log in the backend output?

---

## 8. Explore Networking

**Goal:** Understand how containers communicate using DNS.

### Steps

1. Enter the backend container:
   ```bash
   docker exec -it $(docker compose ps -q backend) sh
   ```

2. Verify DNS resolution to the postgres service:
   ```bash
   ping -c 2 postgres
   ```

3. Verify DNS resolution to the frontend:
   ```bash
   ping -c 2 frontend
   ```

4. Exit the container:
   ```bash
   exit
   ```

5. Inspect the Docker Compose network:
   ```bash
   docker network ls
   docker network inspect solution_default
   ```

### Expected result

- `ping postgres` resolves to the postgres container's IP.
- All three containers are on the same network.
- The network was created automatically by Docker Compose.

### Questions

- Why does the hostname `postgres` work inside the backend container?
- Could the backend reach the frontend by hostname too? When would that be useful?

---

## 9. Explore Environment Variables

**Goal:** Verify that environment variables are correctly injected into containers.

### Steps

1. View the backend's environment:
   ```bash
   docker exec $(docker compose ps -q backend) env | sort
   ```

2. Look for `DATABASE_URI`, `BACKEND_HOST`, `BACKEND_PORT`.

3. View the frontend's environment:
   ```bash
   docker exec $(docker compose ps -q frontend) env | sort
   ```

4. Look for `BACKEND_UPSTREAM`.

### Questions

- How does the backend receive the database connection URI?
- Is `VITE_API_URL` visible in the frontend container's environment? Why or why not?

---

## 10. Explore Volumes and Data Persistence

**Goal:** Verify that PostgreSQL data survives container restarts.

### Steps

1. Create one or two notes through the frontend UI.

2. List Docker volumes:
   ```bash
   docker volume ls
   ```

3. Inspect the postgres volume:
   ```bash
   docker volume inspect solution_postgres_data
   ```

4. Stop and remove all containers (but **not** volumes):
   ```bash
   docker compose down
   ```

5. Start again:
   ```bash
   docker compose up -d
   ```

6. Open the frontend, verify the notes are still there.

7. Now stop and remove containers **including** volumes:
   ```bash
   docker compose down -v
   ```

8. Start again:
   ```bash
   docker compose up -d
   ```

9. Open the frontend, the notes should be gone.

### Expected result

- `docker compose down` (without `-v`) preserves the volume and the data.
- `docker compose down -v` deletes the volume and all stored data is lost.

### Questions

- Where is the data actually stored on the host filesystem?
- What would happen if we didn't use a named volume for PostgreSQL?

---

## 11. Understand the Full Architecture

**Goal:** Verify your mental model of how all the pieces connect.

### Steps

1. Draw the application flow (on paper or digitally):

All three services live inside the Docker Compose network. The Frontend (Caddy, port 80) forwards requests to the Backend (Node.js, port 9090), which connects to PostgreSQL (port 5432). PostgreSQL stores its data in the `postgres_data` named volume. The Frontend is the only service exposed to the host machine through a port mapping of 8080:80, making the application accessible at `localhost:8080`.

2. For each component, identify:
   - Who calls it?
   - What environment variables does it need?
   - Does it need persistent storage?
   - Is it exposed to the host?

---

## Checklist

#### Dockerfiles
- [ ] Backend Dockerfile with multi-stage build (base → build → runner)
- [ ] Frontend Dockerfile with build arg and Caddy (build → runner)
- [ ] `.dockerignore` for both backend and frontend

#### Docker Compose
- [ ] `docker-compose.yml` with three services (postgres, backend, frontend)
- [ ] `.env` file with all required variables
- [ ] Named volume for PostgreSQL data
- [ ] Healthcheck on PostgreSQL with `depends_on` condition

#### Verification
- [ ] Application starts with `docker compose up --build`
- [ ] Frontend loads at `http://localhost:8080`
- [ ] Notes can be created and persist across container restarts
- [ ] Data is lost when using `docker compose down -v`

#### Understanding
- [ ] Can explain why multi-stage builds produce smaller images
- [ ] Can explain the difference between build args and runtime env vars
- [ ] Can explain how containers find each other by service name
- [ ] Can explain the role of Caddy as a reverse proxy
