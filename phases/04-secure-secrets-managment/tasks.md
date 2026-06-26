# Phase 04 — Secure Secrets Management with Bitnami Sealed Secrets

This guide walks through installing Bitnami Sealed Secrets, encrypting your
database credentials with `kubeseal`, and consuming them from the canonical
`todo-app` chart so everything is safe to commit to Git.

From this phase onwards the solution stops copying the chart and consumes the
**single source of truth** at `application/chart`. The only Phase-04-specific
artefacts are the sealed credentials and a small values override.

**Conventions used in this guide:**


| Key                      | Value                          |
| ------------------------ | ------------------------------ |
| Canonical chart          | `application/chart`            |
| Release name             | `my-app`                       |
| App namespace            | `todo`                         |
| Sealed Secrets namespace | `kube-system`                  |
| Secret name              | `todo-db-secret`               |
| Sealed manifest          | `solution/sealed/todo-db-sealedsecret.yaml` |
| Phase values             | `solution/apps/todo-app/values/prod-values.yaml` |

> Commands below are run from `phases/04-secure-secrets-managment/solution/`
> unless noted. The canonical chart is therefore `../../../application/chart`.

---

## How it works

```
kubeseal encrypts your credentials with the controller's public key
     ↓
The encrypted SealedSecret is written to a standalone manifest
(solution/sealed/todo-db-sealedsecret.yaml) and committed to Git
     ↓
kubectl apply sends it to the cluster
     ↓
Sealed Secrets controller decrypts it → creates the todo-db-secret Secret
     ↓
The canonical chart, deployed with postgres.existingSecret: todo-db-secret,
consumes that Secret via envFrom (backend + postgres)
```

The key idea: **encrypted blobs live in a standalone, committable manifest —
never in `values.yaml`, and never copied into the app chart.** The app chart
(`application/chart`) stays the single source of truth and only references the
Secret by name. The plain credentials never leave your machine.

---

## Step 1 — Prerequisites

Verify your tools before starting.

```bash
# Kubernetes cluster is reachable
kubectl get nodes

# Helm is available
helm version --short

# kubeseal is installed
kubeseal --version
```

If `kubeseal` is missing, install it from the [Bitnami Sealed Secrets releases page](https://github.com/bitnami-labs/sealed-secrets/releases).

Create the app namespace if it does not exist yet:

```bash
kubectl create namespace todo --dry-run=client -o yaml | kubectl apply -f -
```

---

## Step 2 — Install the Sealed Secrets controller

The controller runs inside the cluster and holds the private key used to decrypt your secrets.

In production the controller itself is managed as code. The `sealed-secrets/` wrapper chart declares the dependency so the version is pinned and reproducible:

```
apps/sealed-secrets/
├── Chart.yaml    ← declares bitnami-labs/sealed-secrets as a dependency
└── values.yaml   ← fullnameOverride to keep the controller name stable
```

```bash
# Add the Sealed Secrets Helm repo (bitnami-labs org was renamed to bitnami; this is not bitnami/bitnami)
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update

# Pull the dependency into charts/
helm dependency update ./apps/sealed-secrets

# Install the controller in kube-system
helm upgrade --install cluster-sealed-secrets ./apps/sealed-secrets \
  -n kube-system \
  --create-namespace

# Confirm the controller pod is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets

# Confirm the CRD is registered
kubectl get crd | awk '/sealedsecrets/'
# Expected output: sealedsecrets.bitnami.com
```

> **Why a wrapper chart?** It pins the controller version in Git (`Chart.yaml`), lets you track upgrades via pull requests, and makes it reproducible across clusters — the same pattern you would use for Prometheus, Cert-Manager, or any cluster-level dependency.

---

## Step 3 — Seal your credentials (run once, repeat when rotating)

This step produces the encrypted manifest you commit to Git. The bootstrap
script automates exactly these commands in `bootstrap/seal-credentials.sh`;
they are shown here so you understand what it does.

```bash
# 1. Fetch the controller's public certificate
kubeseal --fetch-cert \
  --controller-name sealed-secrets \
  --controller-namespace kube-system \
  > /tmp/sealed-secrets-cert.pem

# 2. Create a plain Secret manifest locally — NEVER commit this file
kubectl create secret generic todo-db-secret \
  -n todo \
  --from-literal=POSTGRES_USER=admin \
  --from-literal=POSTGRES_PASSWORD=password \
  --from-literal=POSTGRES_DB=domain \
  --from-literal=DATABASE_URI='postgres://admin:password@my-app-todo-app-postgres:5432/domain' \
  --dry-run=client -o yaml > /tmp/todo-db-secret.yaml

# 3. Encrypt it into a STANDALONE manifest committed to Git
mkdir -p sealed
kubeseal \
  --format yaml \
  --cert /tmp/sealed-secrets-cert.pem \
  --scope namespace-wide \
  < /tmp/todo-db-secret.yaml \
  > sealed/todo-db-sealedsecret.yaml

# 4. Inspect the result — encrypted blobs under spec.encryptedData
cat sealed/todo-db-sealedsecret.yaml

# 5. Delete the plain file immediately
rm /tmp/todo-db-secret.yaml
```

`sealed/todo-db-sealedsecret.yaml` is safe to commit: the blobs are
cluster-specific and can only be decrypted by the controller that holds the
matching private key.

> **Why a standalone manifest, not a chart template?** A SealedSecret is a
> cluster-specific infrastructure artefact, not application configuration. The
> canonical chart deliberately does not carry it — keeping it out of the chart
> is what lets every phase consume the *same* chart. Production charts like
> `ds-helmchart` go one step further and generate credentials in-cluster (the
> bootstrap-hook pattern you adopt in Phase 05); SealedSecrets is the Git-based
> alternative you learn here first.

---

## Step 4 — Wire it into the canonical chart

You do **not** copy any chart templates. The canonical chart already ships:

- a `todo-app.databaseSecretName` helper in `_helpers.tpl` that returns
  `postgres.existingSecret` when set, otherwise `postgres.secretName`;
- `envFrom: secretRef` on both the backend and Postgres deployments, pointed at
  that helper — so both consume `todo-db-secret` as the single source of truth.

The phase override `apps/todo-app/values/prod-values.yaml` sets:

```yaml
postgres:
  existingSecret: "todo-db-secret"   # consume the sealed Secret; skip the bootstrap hook
  persistence:
    storageClassName: "local-path"   # no Longhorn yet (that arrives in Phase 05)
```

Setting `existingSecret` makes the chart use the Secret the controller created
from your SealedSecret, and disables the chart's own in-cluster bootstrap hook
(`postgres-secret-bootstrap.yaml` is gated on `not existingSecret`). That hook
is the Phase 05+ pattern; here you supply the Secret yourself.

Apply the sealed manifest so the controller materializes `todo-db-secret`:

```bash
kubectl apply -f sealed/todo-db-sealedsecret.yaml

# The controller decrypts it into a plain Secret
kubectl get sealedsecret,secret todo-db-secret -n todo
```

---

## Step 5 — Deploy

Deploy the canonical chart with the phase override:

```bash
helm upgrade --install my-app ../../../application/chart \
  -n todo \
  -f apps/todo-app/values/prod-values.yaml \
  --set frontend.image.repository="docker.io/<dockerhub-user>/todo-frontend" \
  --set backend.image.repository="docker.io/<dockerhub-user>/todo-backend"
```

Or run `bootstrap/bootstrap.sh`, which installs the controller, seals and
applies the credentials, builds/pushes the images, and deploys — all from
`application/chart`.

---

## Step 6 — Verify

```bash
# Both the SealedSecret and the decrypted Secret should appear
kubectl get sealedsecret,secret -n todo | grep todo-db-secret

# Check all resources in the namespace look healthy
kubectl get sealedsecret,secret,deploy,pods,svc -n todo

# Inspect backend logs for any DB connection errors
kubectl logs deploy/my-app-todo-app-backend -n todo --tail=100
```

If something is wrong, these commands help narrow it down:

```bash
kubectl describe sealedsecret todo-db-secret -n todo
kubectl get events -n todo --sort-by=.lastTimestamp
kubectl logs -n kube-system deploy/sealed-secrets
```

---

## Troubleshooting checklist

- Sealed Secrets controller is running in `kube-system`
- `kubeseal` was run against the correct controller name and namespace
- The encrypted blobs in `sealed/todo-db-sealedsecret.yaml` came from the same cluster
- `postgres.existingSecret` is set to `todo-db-secret` in the phase values
  (otherwise the chart's bootstrap hook runs instead and generates a different Secret)
- `todo-db-secret` exists in the `todo` namespace before the pods start

---

## Credential rotation

When you need to change credentials, repeat Step 3 with the new values
(overwriting `sealed/todo-db-sealedsecret.yaml`), re-apply, and redeploy:

```bash
kubectl apply -f sealed/todo-db-sealedsecret.yaml
helm upgrade --install my-app ../../../application/chart \
  -n todo -f apps/todo-app/values/prod-values.yaml
```

Or simply rerun `bootstrap/seal-credentials.sh --redeploy`.

Never seal secrets during `helm upgrade`. CI/CD should only ever apply encrypted values already committed to Git.

---

## Beyond manual sealing — the bootstrap hook pattern

Manual SealedSecrets are useful because they teach the full encryption flow: `kubeseal` encrypts with the controller's public key, Git stores only encrypted blobs, and the controller decrypts them inside the cluster. That model also has operational costs. Every credential rotation requires re-sealing and committing new blobs, the encrypted values only work with the controller that created the matching private key, and teams must keep the sealing workflow consistent across clusters.

Starting in Phase 05, the todo-app chart uses a Helm bootstrap hook instead. A small `pre-install,pre-upgrade` Job creates the database Secret inside the cluster if it does not already exist. When no password is provided, the Job generates one once and then exits without rotating it on later upgrades. This keeps todo-app credentials entirely out of Git, removes manual sealing from the app workflow, and makes repeated `helm upgrade` runs idempotent. It is the same in-cluster generation pattern production charts like `ds-helmchart` use for their own credentials.

SealedSecrets still matter for cases where secrets must be prepared before an application starts and cannot be generated simply in-cluster. Phase 07 uses that approach for authentik, while todo-app continues to use the bootstrap hook.

---

## Extra exercises

These are optional but build real understanding of Sealed Secrets behavior.

1. **Scope comparison** — seal a secret with `--scope strict`, then change its name or namespace and re-apply. Observe that decryption fails. Understand why `namespace-wide` is more flexible.
2. **Tamper test** — change one character in an encrypted blob in `sealed/todo-db-sealedsecret.yaml`, apply, and observe the controller error.
3. **Wrong-cluster test** — apply the same `SealedSecret` in a different cluster. It cannot decrypt because the key pair is different.
4. **Controller downtime** — scale the controller to 0 replicas, apply a new `SealedSecret`, then scale back to 1 and watch it reconcile.
5. **Git hygiene** — confirm no plain secret file was ever committed: `git log --all --full-history -- "*secret*"`.

---

## Additional reading

- [External Secrets Operator](https://external-secrets.io/latest/) — alternative approach using an external secrets store
- [HashiCorp Vault](https://developer.hashicorp.com/vault) — enterprise-grade secrets management

---

## Success criteria

- Sealed Secrets controller installed with Helm and CRD available
- DB credentials sealed with `kubeseal` and plain file deleted immediately
- `sealed/todo-db-sealedsecret.yaml` committed to Git with encrypted blobs only
- The phase deploys the canonical `application/chart` (no copied chart templates)
- `postgres.existingSecret: todo-db-secret` consumes the sealed Secret and skips the bootstrap hook
- Backend and Postgres both consume `todo-db-secret` as the single source of truth
- End-to-end deployment works with no plaintext credentials anywhere in Git
- Extra exercises completed and findings documented
