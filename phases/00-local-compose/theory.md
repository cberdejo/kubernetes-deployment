# Phase 00 — Local Docker Compose

This phase establishes the foundational concepts before moving on to Kubernetes.

Kubernetes does not run applications directly.  
It runs **containers**.

Therefore, before working with Kubernetes, it's necessary to understand:

- what a container is
- how to run applications in containers
- how containers communicate
- how to configure them

Docker Compose allows you to define a microservices architecture locally.

---

# Application Architecture

The application consists of three services:

- Frontend  
- Backend  
- Database

---

# Services Defined in Docker Compose

## Frontend

Responsibilities:

- serve the web interface
- send HTTP requests to the backend

Technologies:

- Vite / React
- Nginx or a static file server

---

## Backend

Responsibilities:

- expose a REST API
- execute business logic
- access the database

Technologies:

- API server

---

## Database

Responsibilities:

- persist data
- manage storage

Technologies:

- PostgreSQL

---

# Networking in Docker Compose

Docker Compose automatically creates an internal network.

Containers can communicate with each other using **the service name**.

Example:

`postgres://user:password@postgres:5432/chatdb`


Here, the hostname `postgres` is the service name.

---

# Data Persistence

The database uses a **volume**.

```
volumes:
    postgres_data
```

This allows data to survive container restarts.

---

# Environment Variables

Docker Compose allows you to configure applications using:

- `environment`
- `env_file`

This makes it possible to separate configuration from code.

Example:

```
POSTGRES_USER  
POSTGRES_PASSWORD  
DATABASE_URI  
```

---

# Service Dependencies

Docker Compose allows you to define dependencies using:

```
depends_on
```

This indicates the startup order of containers.

Kubernetes **does not work exactly like this**—we’ll see the differences in later phases.

---

# What We Are Really Learning

This phase teaches:

- service architecture
- networking between containers
- data persistence
- application configuration

All of these concepts will show up later in Kubernetes, although the mechanisms are different.