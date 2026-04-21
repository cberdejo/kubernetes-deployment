# Phase 03 — Package Management and Templating with Helm

This guide details the transformation of static Kubernetes manifests (from Phase 02) into a reusable Helm Chart.

**Conventions used in this guide:**
* Working directory: Project root
* Chart name: `todo-app`
* Release name: `my-app`
* Namespace: `todo`

---

## 1. Environment Preparation

Before starting, make sure your tools are ready and your cluster is running.

1. **Verify Helm:**
   ```bash
   helm version --short
   ```
   *(If you don't have it, install it from [helm.sh/docs/intro/install/](https://helm.sh/docs/intro/install/))*

2. **Verify Kubernetes Context:**
   Make sure you are pointing to your local cluster and that the nodes are ready:
   ```bash
   kubectl get nodes
   ```

3. **Create the Working Namespace:**
   It is a good practice to create the namespace outside of Helm to avoid lifecycle conflicts:
   ```bash
   kubectl create namespace todo
   kubectl config set-context --current --namespace=todo
   ```

---

## 2. Chart Creation and Base Migration

1. **Generate the Base Structure (Scaffold):**
   ```bash
   helm create todo-app
   ```
   This creates the default directories and files (`Chart.yaml`, `values.yaml`, `templates/`).

2. **Clean up Default Templates:**
   Delete all contents inside the `templates/` folder **except** `_helpers.tpl` and `NOTES.txt` (optional). We don't need Helm's example application.

3. **Migrate Static Manifests:**
   Copy all your `.yaml` files from Phase 02 (Deployments, Services, PVCs, ConfigMaps, Secrets) into the `todo-app/templates/` folder.

---

## 3. Understanding Parameterization (The Core of Helm)

The goal of Helm is that you should never have to manually edit the files in `templates/` again. Instead, you leave "placeholders" (variables) that are populated using the `values.yaml` file.

The syntax Helm uses (based on Go Templates) is `{{ .Values.path.to.variable }}`.

### Practical Example: From Static to Dynamic

**Before (Static Manifest in `templates/frontend-deployment.yaml`):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: frontend
        image: my-repo/frontend:v1.0.0
```

**After (Helm Template):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  # Uses the helper function to generate a unique name
  name: {{ include "todo-app.fullname" . }}-frontend
spec:
  # Points to values.yaml
  replicas: {{ .Values.frontend.replicaCount }}
  template:
    spec:
      containers:
      - name: frontend
        image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
```

### Structuring `values.yaml`

For the template above to work, your `values.yaml` file must be logically structured, separated by components:

```yaml
# File: todo-app/values.yaml

frontend:
  replicaCount: 3
  image:
    repository: my-repo/frontend
    tag: v1.0.0
  service:
    type: NodePort
    port: 80
    nodePort: 30080

backend:
  replicaCount: 2
  image:
    repository: my-repo/backend
    tag: v1.0.0

postgres:
  persistence:
    enabled: true
    size: 1Gi
```

**Golden Rule for Secrets:** Do not put real passwords in `values.yaml`. Leave them empty or use fake development values. We will inject them at deployment time.

---

## 4. Local Validation

Before installing anything on the cluster, check that your templates render correctly with your values.

1. **Linter (Checks for syntax errors and best practices):**
   ```bash
   helm lint ./todo-app
   ```

2. **Rendering (See the final generated YAML):**
   ```bash
   helm template my-app ./todo-app > /tmp/my-app-rendered.yaml
   ```
   *Review the `/tmp/my-app-rendered.yaml` file to ensure the variables were injected properly (names, ports, images).*

3. **Simulation (Dry-run against the cluster):**
   ```bash
   helm install my-app ./todo-app --dry-run --debug
   ```

---

## 5. Deployment and Verification

1. **Install the Release:**
   For this lab, pass credentials with `--set` so Helm can generate the chart-managed Secret:
   ```bash
   helm upgrade --install my-app ./todo-app \
     -n todo --create-namespace \
     --set postgres.secret.username=admin \
     --set postgres.secret.password=password \
     --set postgres.secret.database=domain \
     --set-string postgres.secret.databaseUri="postgres://admin:password@my-app-todo-app-postgres:5432/domain"
   ```
   This creates the default Secret used by both PostgreSQL and Backend (`my-app-todo-app-postgres-secret`).

2. **Verify Status in Kubernetes:**
   ```bash
   kubectl get all,pvc,secrets,configmaps -n todo
   ```
   Check that Pods are `Running`, PVC is `Bound`, and the default Secret exists.

3. **End-to-End Test:**
   Get the frontend NodePort and open the app in your browser:
   ```bash
   kubectl get svc -n todo
   ```
   Then verify Frontend, Backend, and DB communication at `http://<NODE-IP>:<NODEPORT>`.

---

## 6. Lifecycle: Upgrades and Rollbacks

Helm shines when managing changes across environments.

Before upgrading with new values, move credentials out of CLI flags and into a reusable Kubernetes Secret.

1. **Create (or Update) a Kubernetes Secret for DB Credentials:**
   This avoids repeating sensitive flags on every release:
   ```bash
   kubectl create secret generic todo-db-secret -n todo \
     --from-literal=POSTGRES_USER=admin \
     --from-literal=POSTGRES_PASSWORD=password \
     --from-literal=POSTGRES_DB=domain \
     --from-literal=DATABASE_URI='postgres://admin:password@my-app-todo-app-postgres:5432/domain' \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

2. **Create an Environment File (e.g., Production):**
   Create a file (for example `values-prod.yaml`) and reference the same Secret from **both** components:
   ```yaml
   postgres:
     existingSecret: todo-db-secret

   backend:
     existingSecret: todo-db-secret
     replicaCount: 3

   frontend:
     image:
       tag: v2.0.0
   ```
   > Important: if you set only `postgres.existingSecret` and forget `backend.existingSecret`, the backend will still look for the default Secret name and can fail with `secret "...-postgres-secret" not found`.

3. **Upgrade the Release Using the Environment File:**
   ```bash
   helm upgrade --install my-app ./todo-app \
     -f ./todo-app/values-prod.yaml \
     -n todo
   ```
   This approach avoids exposing sensitive values in Helm command history.


4. **Verify the History:**
   ```bash
   helm history my-app -n todo
   ```
   *You will see REVISION 1 (Install) and REVISION 2 (Upgrade).*

5. **Undo the Change (Rollback):**
   If the production version fails, quickly revert to the previous revision:
   ```bash
   helm rollback my-app 1 -n todo
   ```

6. **Production Note (Recommended Approach):**
   Passing secrets with `--set` or storing plain Secret manifests in Git is mainly acceptable for local labs and learning. In real production platforms this is almost never done directly, because they are stored in base64 in the cluster, which is easily reversed to plain text, it provides absolutely zero security, confidentiality, or protection against unauthorized access.

---

## 7. Recommended Reading
[Create Your First Helm Chart](https://techdocs.broadcom.com/us/en/vmware-tanzu/bitnami-secure-images/bitnami-secure-images/services/bsi-doc/apps-tutorials-create-first-helm-chart-index.html)

## 8. Phase 03 Success Criteria

[ ] The `todo-app` Chart was created and default templates were cleaned up.
[ ] Static manifests have been parameterized (images, replicas, ports, persistence) pointing to `values.yaml`.
[ ] `helm lint` and `helm template` run without errors.
[ ] The full application deploys successfully with `helm install` and works end-to-end.
[ ] `helm upgrade` (with a different values file) and `helm rollback` were tested successfully.
