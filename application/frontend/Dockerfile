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


FROM nginx:alpine AS runner

WORKDIR /usr/share/nginx/html

# Remove default nginx static assets
RUN rm -rf ./*

# Copy built files from Vite
COPY --from=build /app/dist ./

# Simple default nginx config (can be overridden with your own)
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

