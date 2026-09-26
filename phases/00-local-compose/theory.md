# Phase 00 - Local Docker Compose

- **Core concepts to master in this phase**:
  - **Containers**
  - **Docker images**
  - **Dockerfile**
  - **Multi-stage builds**
  - **Docker Compose**
  - **Volumes**
  - **Networking between containers**
  - **Environment variables vs build arguments**

## Why This Phase Exists

Kubernetes does not run applications directly. It runs **containers**.

Before moving into Kubernetes, you need to understand:

- what a container is and how it isolates a process,
- how to package an application into a container image,
- how containers communicate over a network,
- how to configure them without changing the code,
- how to persist data outside the container lifecycle.

Docker Compose allows you to define and run a complete microservices architecture locally. Every concept here (images, networking, volumes, environment variables) will reappear in Kubernetes, although the mechanisms are different.

---

## Application Architecture

The application is a simple note-taking app with three components:

| Component | Technology | Role |
|---|---|---|
| **Frontend** | Vite / React + Caddy | Serves the web interface and proxies API calls to the backend |
| **Backend** | Node.js / Express + TypeScript | Exposes a REST API, executes business logic, accesses the database |
| **Database** | PostgreSQL 15 | Persists data |

The communication flow is:

```
Browser → Frontend (Caddy reverse proxy) → Backend (REST API) → PostgreSQL
```

The frontend never talks to the database directly. The backend is the only component that accesses PostgreSQL.

---

## 1. Containers and Images

A **container** is an isolated process that runs with its own filesystem, network, and process tree. Unlike a virtual machine, it shares the host kernel, this makes containers lightweight and fast to start.

A **container image** is a read-only template used to create containers. It includes:

- a base operating system (usually a minimal Linux distribution),
- application code and dependencies,
- configuration for how the process should start.

Images are **built in layers**. Each instruction in a Dockerfile creates a new layer. Layers are cached, if nothing changed in a layer, Docker reuses it from cache, which speeds up builds significantly.

---

## 2. Dockerfile Fundamentals

A **Dockerfile** is a text file with instructions that Docker follows to build an image.

### Key instructions

| Instruction | Purpose |
|---|---|
| `FROM` | Sets the base image. Every Dockerfile starts with at least one `FROM`. |
| `WORKDIR` | Sets the working directory inside the container for subsequent instructions. |
| `COPY` | Copies files from the host into the image. |
| `RUN` | Executes a command during the build (e.g., install dependencies, compile code). |
| `EXPOSE` | Documents which port the container listens on. It does **not** publish the port, that is done at runtime. |
| `ENV` | Sets an environment variable that persists into the running container. |
| `ARG` | Defines a build-time variable. Only available during the build, not at runtime. |
| `CMD` | Specifies the default command to run when the container starts. |

### Layer caching and build order

Docker caches each layer. If a layer and all layers before it haven't changed, Docker skips rebuilding them. This means **instruction order matters**:

```dockerfile
# Good: dependencies are cached separately from source code
COPY package.json package-lock.json ./
RUN npm ci
COPY src ./src
```

If you change a source file, only `COPY src ./src` and subsequent layers are rebuilt. The `npm ci` layer is reused from cache because `package.json` didn't change.

```dockerfile
# Bad: any source change invalidates the npm install cache
COPY . .
RUN npm ci
```

---

## 3. Multi-Stage Builds

A **multi-stage build** uses multiple `FROM` instructions in one Dockerfile. Each `FROM` starts a new build stage with its own filesystem. You can copy files from one stage to another with `COPY --from=<stage>`.

This is essential for keeping production images small and secure:

- **Build stage**: install all dependencies (including dev), compile/build the application.
- **Production stage**: start from a clean base, copy only the compiled output and production dependencies.

### Backend Dockerfile (multi-stage)

The backend is a TypeScript Node.js application that needs to be compiled to JavaScript:

```dockerfile
# Stage 1: Base - shared setup
FROM node:20-alpine AS base
WORKDIR /app
COPY package.json package-lock.json ./

# Stage 2: Build - compile TypeScript
FROM base AS build
RUN npm ci                        # all dependencies (including dev)
COPY tsconfig.json ./tsconfig.json
COPY src ./src
RUN npm run build                 # outputs to dist/

# Stage 3: Production runtime
FROM node:20-alpine AS runner
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev             # only production dependencies
COPY --from=build /app/dist ./dist
COPY --from=build /app/tsconfig.json ./tsconfig.json
EXPOSE 8080
ENV BACKEND_HOST=0.0.0.0
ENV BACKEND_PORT=8080
CMD ["node", "dist/index.js"]
```

Why three stages:

1. The `base` stage is reused by the `build` stage (shared `COPY` of package files).
2. The `build` stage installs dev dependencies and compiles TypeScript. This stage is discarded in the final image.
3. The `runner` stage starts fresh from `node:20-alpine`, installs only production dependencies, and copies the compiled JavaScript from the build stage. The final image does not contain TypeScript source, dev dependencies, or build tools.

### Frontend Dockerfile (multi-stage with build arg)

The frontend is a Vite/React SPA that compiles to static files, served by Caddy:

```dockerfile
# Stage 1: Build the React app
FROM node:20-alpine AS build
WORKDIR /app
ARG VITE_API_URL                  # build-time variable for the API endpoint
ENV VITE_API_URL=$VITE_API_URL
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build                 # outputs to dist/

# Stage 2: Serve static files with Caddy
FROM caddy:2-alpine AS runner
COPY --from=build /app/dist /usr/share/caddy
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 80
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
```

Key details:

- `ARG VITE_API_URL` is a **build argument**. Vite inlines environment variables that start with `VITE_` into the JavaScript bundle at build time. This value cannot be changed at runtime, it's baked into the compiled assets.
- The production image uses `caddy:2-alpine` instead of Node.js. Caddy is a lightweight web server that serves the static files and acts as a reverse proxy to the backend.
- The final image contains only Caddy and the compiled HTML/CSS/JS, no Node.js, no source code, no `node_modules`.

---

## 4. The Reverse Proxy Pattern (Caddyfile)

The frontend container uses Caddy not just as a static file server, but as a **reverse proxy**:

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

How this works:

- Requests to `/api/v1*` are forwarded to the backend service (the `BACKEND_UPSTREAM` environment variable resolves to `backend:9090` in Docker Compose).
- All other requests serve static files, with a fallback to `index.html` for client-side routing (SPA behavior).

This pattern is important because:

- The browser talks to a single origin (the frontend), avoiding CORS issues.
- The backend is never exposed directly to the outside world.
- The same pattern applies in Kubernetes with Ingress or Gateway API routing.

---

## 5. .dockerignore

The `.dockerignore` file tells Docker which files to **exclude** from the build context when running `COPY`. This is similar to `.gitignore`.

A typical `.dockerignore` for a Node.js project:

```
node_modules
dist
.git
.env
*.env
Dockerfile*
```

Why this matters:

- **Performance**: skipping `node_modules` (which can be hundreds of MB) makes the build context much smaller and faster to transfer.
- **Correctness**: if `node_modules` is copied into the image, it may contain platform-specific binaries that don't work in the container's Linux environment. `npm ci` inside the container installs the correct versions.
- **Security**: `.env` files and other secrets should never be included in an image.

---

## 6. Docker Compose

Docker Compose is a tool for defining and running multi-container applications. A `docker-compose.yml` file describes all services, their configuration, networking, and volumes in one place.

### Key concepts in the compose file

#### services

Each entry under `services` defines one container:

```yaml
services:
  postgres:
    image: postgres:15             # uses a pre-built image from Docker Hub
  backend:
    build:
      context: ./application/backend
      dockerfile: Dockerfile        # builds the image from a Dockerfile
  frontend:
    build:
      context: ./application/frontend
      dockerfile: Dockerfile
      args:
        VITE_API_URL: "/api/v1"    # build argument passed to the Dockerfile
```

The `image` field pulls an existing image. The `build` field builds an image from a Dockerfile. Build `args` are passed to `ARG` instructions in the Dockerfile.

#### ports

Maps a host port to a container port:

```yaml
frontend:
  ports:
    - "8080:80"    # host:container
```

Only the frontend exposes ports to the host. The backend and database communicate internally.

#### volumes

Named volumes persist data beyond the container lifecycle:

```yaml
services:
  postgres:
    volumes:
      - postgres_data:/var/lib/postgresql/data
volumes:
  postgres_data:
```

The data directory of PostgreSQL is stored in a named volume. When the container is destroyed and recreated, the volume survives, the data is preserved.

#### environment and env_file

```yaml
backend:
  env_file:
    - ./.env
  environment:
    BACKEND_HOST: 0.0.0.0
    DATABASE_URI: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
```

- `env_file` loads variables from a file.
- `environment` sets or overrides variables inline.
- `${VARIABLE}` syntax interpolates values from the `.env` file or the host environment.

#### depends_on and healthcheck

```yaml
backend:
  depends_on:
    postgres:
      condition: service_healthy

postgres:
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
    interval: 5s
    timeout: 5s
    retries: 20
    start_period: 10s
```

`depends_on` with a `condition: service_healthy` ensures the backend only starts after PostgreSQL is ready to accept connections, not just when the container is running, but when the health check passes.

> Kubernetes **does not have `depends_on`**. Instead, applications must handle startup order themselves (e.g., retry database connections). This difference becomes relevant in Phase 02.

---

## 7. Networking in Docker Compose

Docker Compose automatically creates an **internal network** for all services in the file. Containers can reach each other using **the service name as hostname**.

```
postgres://user:password@postgres:5432/chatdb
                         ^^^^^^^
                         service name = hostname
```

This is DNS-based service discovery, Docker's internal DNS resolves `postgres` to the IP address of the postgres container. This is conceptually the same as Kubernetes Services, which also use DNS names to route traffic between Pods.

Only ports explicitly published with `ports` are accessible from the host machine. Internal communication between containers does not require port mapping.

---

## 8. Environment Variables: Build-time vs Runtime

Understanding the difference is critical:

| | Build-time (`ARG`) | Runtime (`ENV` / `environment`) |
|---|---|---|
| When available | During `docker build` only | When the container runs |
| Defined in | `ARG` in Dockerfile, `args` in Compose | `ENV` in Dockerfile, `environment` / `env_file` in Compose |
| Can change without rebuilding | No, requires a new build | Yes, just restart the container |
| Use case | Values baked into compiled output (e.g., `VITE_API_URL`) | Database credentials, feature flags, service URLs |

In this application:

- `VITE_API_URL` is a **build argument** because Vite inlines it into the JavaScript bundle during compilation.
- `DATABASE_URI`, `POSTGRES_USER`, `POSTGRES_PASSWORD` are **runtime variables** because they are read by the backend process when it starts.

---

## 9. What We Are Really Learning

This phase teaches:

| Concept | Docker Compose mechanism | Kubernetes equivalent |
|---|---|---|
| Service architecture | Multiple services in one file | Multiple Deployments + Services |
| Container images | Dockerfile + `docker build` | Same Dockerfiles, images stored in a registry |
| Networking | Automatic DNS by service name | Service DNS (`service-name.namespace.svc.cluster.local`) |
| Data persistence | Named volumes | PersistentVolumeClaims (PVCs) |
| Non-sensitive configuration | `environment` / `env_file` | ConfigMaps |
| Sensitive configuration | `.env` file (not committed) | Secrets |
| Startup dependencies | `depends_on` + healthcheck | Init containers, readiness probes, retry logic |
| Reverse proxy | Caddy in the frontend container | Ingress / Gateway API |

Every concept learned here transfers directly to Kubernetes. The mechanisms change (Kubernetes is declarative, distributed, and self-healing) but the underlying problems (how do services find each other? where does data live? how is configuration injected?) remain the same.
