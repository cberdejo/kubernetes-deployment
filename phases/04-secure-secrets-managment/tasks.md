# Phase 04 — Secure Secrets Management with Bitnami Sealed Secrets

This guide walks through installing Bitnami Sealed Secrets, encrypting your database credentials with `kubeseal`, and wiring them into the `todo-app` Helm chart so everything is safe to commit to Git.

**Conventions used in this guide:**


| Key                      | Value            |
| ------------------------ | ---------------- |
| Chart name               | `todo-app`       |
| Release name             | `my-app`         |
| App namespace            | `todo`           |
| Sealed Secrets namespace | `kube-system`    |
| Secret name              | `todo-db-secret` |


---

## How it works

```
kubeseal encrypts your credentials using the controller's public key
     ↓
You paste the encrypted blobs directly into
templates/database/postgres-sealedsecret.yaml and commit the file to Git
     ↓
helm upgrade renders and applies the SealedSecret to the cluster
     ↓
Sealed Secrets controller decrypts it → creates a plain Kubernetes Secret
     ↓
Backend and Postgres pods consume that Secret via envFrom
```

The key idea: **encrypted blobs live in the Helm template, never in `values.yaml`**. The `values.yaml` stays free of credentials. The plain credentials never leave your machine.

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
sealed-secrets/
├── Chart.yaml    ← declares bitnami-labs/sealed-secrets as a dependency
└── values.yaml   ← fullnameOverride to keep the controller name stable
```

```bash
# Add the Bitnami Labs Helm repo (different from bitnami/bitnami)
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# Pull the dependency into charts/
helm dependency update ./sealed-secrets

# Install the controller in kube-system
helm upgrade --install cluster-sealed-secrets ./sealed-secrets \
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

This step produces the encrypted blobs that go directly into the Helm template.

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

# 3. Encrypt it with kubeseal
kubeseal \
  --format yaml \
  --cert /tmp/sealed-secrets-cert.pem \
  --scope namespace-wide \
  < /tmp/todo-db-secret.yaml \
  > /tmp/todo-db-sealedsecret.yaml

# 4. Inspect the result — you should see encrypted blobs under spec.encryptedData
cat /tmp/todo-db-sealedsecret.yaml

# 5. Delete the plain file immediately
rm /tmp/todo-db-secret.yaml
```

Open `/tmp/todo-db-sealedsecret.yaml` and copy each value from `spec.encryptedData.*` into `templates/database/postgres-sealedsecret.yaml` (see Step 4 below). You are editing a template file that gets committed to Git — the encrypted blobs are safe to commit.

---

## Step 4 — Add the SealedSecret template to your chart

Create `todo-app/templates/database/postgres-sealedsecret.yaml` and paste the encrypted blobs from Step 3 directly into the file:

```yaml
{{- if not .Values.postgres.existingSecret }}
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: todo-db-secret
  namespace: {{ .Release.Namespace | quote }}
  labels:
    {{- include "todo-app.labels" . | nindent 4 }}
    app.kubernetes.io/component: postgres
spec:
  encryptedData:
    DATABASE_URI: "<paste your encrypted DATABASE_URI here>"
    POSTGRES_DB: "<paste your encrypted POSTGRES_DB here>"
    POSTGRES_PASSWORD: "<paste your encrypted POSTGRES_PASSWORD here>"
    POSTGRES_USER: "<paste your encrypted POSTGRES_USER here>"
  template:
    metadata:
      name: todo-db-secret
      namespace: {{ .Release.Namespace | quote }}
      labels:
        {{- include "todo-app.labels" . | nindent 8 }}
        app.kubernetes.io/component: postgres
    type: Opaque
{{- end }}
```

> **Why `{{- if not .Values.postgres.existingSecret }}`?** This guard skips the template when `postgres.existingSecret` is set to a non-empty value — useful when a secret already exists in the cluster (e.g., managed by an external secrets operator in production).

> **Why not use `values.yaml` for the blobs?** Encrypted values are cluster-specific: they can only be decrypted by the controller that holds the matching private key. Keeping them in the template makes it obvious they are infrastructure artefacts tied to a specific cluster, not configuration that varies per environment.

Define the secret name explicitly in `values.yaml`:

```yaml
postgres:
  secretName: "todo-db-secret"
  existingSecret: ""   # set this to skip the SealedSecret and use a pre-existing secret
```

Add a helper in `_helpers.tpl` that reads it:

```yaml
{{- define "todo-app.databaseSecretName" -}}
{{- if .Values.postgres.existingSecret }}
{{- .Values.postgres.existingSecret }}
{{- else }}
{{- required "postgres.secretName is required" .Values.postgres.secretName }}
{{- end }}
{{- end }}
```

Use the helper everywhere the secret name appears — both deployments and the SealedSecret metadata:

```yaml
# postgres-sealedsecret.yaml
metadata:
  name: {{ include "todo-app.databaseSecretName" . }}
  ...
  template:
    metadata:
      name: {{ include "todo-app.databaseSecretName" . }}

# postgres-deployment.yaml and backend-deployment.yaml
envFrom:
  - secretRef:
      name: {{ include "todo-app.databaseSecretName" . }}
```

The name lives in one place (`values.yaml`). The `required` call makes Helm fail with a clear error if it is ever left empty.

---

## Step 5 — Deploy

```bash
helm upgrade --install my-app ./todo-app \
  -n todo \
  -f ./todo-app/values.yaml
```

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
- The encrypted blobs in `postgres-sealedsecret.yaml` came from the same cluster
- `postgres.existingSecret` in `values.yaml` is empty (otherwise the template is skipped)
- No leftover plain `Secret` template is being rendered at the same time

---

## Credential rotation

When you need to change credentials, repeat Step 3 with the new values, update the encrypted blobs in `postgres-sealedsecret.yaml`, and redeploy:

```bash
helm upgrade --install my-app ./todo-app -n todo -f ./todo-app/values.yaml
```

Never seal secrets during `helm upgrade`. CI/CD should only ever apply encrypted values already committed to Git.

---

## Extra exercises

These are optional but build real understanding of Sealed Secrets behavior.

1. **Scope comparison** — seal a secret with `--scope strict`, then change its name or namespace and re-apply. Observe that decryption fails. Understand why `namespace-wide` is more flexible.
2. **Tamper test** — change one character in an encrypted blob in `postgres-sealedsecret.yaml`, apply, and observe the controller error.
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
- `todo-app` chart has `postgres-sealedsecret.yaml` with encrypted blobs committed to Git
- `values.yaml` contains zero plaintext credentials
- Backend and Postgres both consume `todo-db-secret` as the single source of truth
- End-to-end deployment works with no plaintext credentials anywhere in Git
- Extra exercises completed and findings documented

