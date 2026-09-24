# todo-app Helm Chart

This is the canonical Helm chart for the todo-app. It is the single source of truth for deploying the application across all phases and environments.

## Origin

This chart is built from scratch in [Phase 03 — Package Management](../../phases/03-package-managment/). That phase walks through creating a Helm chart from static manifests, parameterizing templates with `values.yaml`, and testing the full Helm lifecycle (install, upgrade, rollback). At the end of Phase 03 the chart graduates here, and every subsequent phase consumes it without copying.

## How phases consume this chart

From Phase 04 onwards, each phase provides only a **values override file** — the chart templates are never duplicated. Each override enables the features relevant to that phase while the chart stays in one place.

```bash
helm upgrade --install my-app ../../application/chart \
  -n todo \
  -f apps/todo-app/values/prod-values.yaml
```

This is the standard GitOps pattern: one chart, many environments. Every feature is gated behind a value flag so the same chart serves development, staging, and production — only the values change.

## Components

The chart deploys:

- **Frontend** — Caddy-based SPA with reverse proxy to the backend
- **Backend** — Node.js API connected to PostgreSQL
- **PostgreSQL** — single-replica database with PVC persistence
- **Optional:** Gateway API HTTPRoute, ExtAuth (authentik), security policies

## PostgreSQL Secret Bootstrap

When `postgres.existingSecret` is empty and `postgres.bootstrap.enabled` is true, a `pre-install,pre-upgrade` hook creates `todo-db-secret` if it does not already exist.

The hook never rotates an existing Secret. Omit `postgres.bootstrap.credentials.password`, or leave it empty in an override file, to generate one alphanumeric password once in-cluster. Set it only when you need a fixed URI-safe value for CI, restore, or deterministic installs.

## Publish to OCI

From `phases/06-routing-and-traffic-exposure/solution`:

```bash
source bootstrap/.env

helm registry login registry-1.docker.io \
  --username "$DOCKERHUB_USER"

./scripts/publish-chart.sh
```

The script reads `bootstrap/.env`, packages `application/chart`, and pushes:

```text
oci://registry-1.docker.io/<dockerhub-user>/todo-app:0.1.0
```

## Install from OCI

```bash
helm upgrade --install my-app \
  oci://registry-1.docker.io/<dockerhub-user>/todo-app \
  --version 0.1.0 \
  -f values/prod-values.yaml \
  -n todo
```
