FROM node:20-alpine AS base

WORKDIR /app

# Install only production dependencies later, but keep lockfile for reproducible installs
COPY package.json package-lock.json ./


# ---------- Build stage ----------
FROM base AS build

# Install all dependencies (including dev) to build TypeScript
RUN npm ci

COPY tsconfig.json ./tsconfig.json
COPY src ./src

# Output will go to dist/ (configured in tsconfig or via tsc defaults)
RUN npm run build


# ---------- Production runtime ----------
FROM node:20-alpine AS runner

ENV NODE_ENV=production
WORKDIR /app

# Install only production dependencies
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Copy compiled JavaScript from build stage
COPY --from=build /app/dist ./dist

# Copy any other assets/config that runtime might need
COPY --from=build /app/tsconfig.json ./tsconfig.json

# Expose backend port (can be overridden with env)
EXPOSE 8080

# Default envs (can be overridden at runtime)
ENV BACKEND_HOST=0.0.0.0
ENV BACKEND_PORT=8080

CMD ["node", "dist/index.js"]

