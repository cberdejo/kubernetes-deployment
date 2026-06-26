# todo-app Helm Chart

This is the canonical todo-app Helm chart for the repository. Phase solutions should reference this chart instead of carrying their own copies.

It deploys the todo-app frontend, backend, PostgreSQL database, and optional Gateway API HTTPRoute.

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

## PostgreSQL Secret Bootstrap

When `postgres.existingSecret` is empty and `postgres.bootstrap.enabled` is true, a `pre-install,pre-upgrade` hook creates `todo-db-secret` if it does not already exist.

The hook never rotates an existing Secret. Omit `postgres.bootstrap.credentials.password`, or leave it empty in an override file, to generate one alphanumeric password once in-cluster. Set it only when you need a fixed URI-safe value for CI, restore, or deterministic installs.
