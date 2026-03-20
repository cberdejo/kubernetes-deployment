FROM node:20-alpine AS build

WORKDIR /app

# Build-time env for Vite
ARG VITE_API_URL
ENV VITE_API_URL=$VITE_API_URL

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Build static assets
RUN npm run build


FROM caddy:2-alpine AS runner

# Copy built files from Vite
COPY --from=build /app/dist /usr/share/caddy
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 80

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

