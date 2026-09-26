# Phase 08 - Private Container Registry with Harbor

This phase deploys Harbor as a private container registry, pushes the todo-app images to it, and reconfigures the application to pull from Harbor instead of a public registry. You will also learn how to publish Helm charts as OCI artifacts and manage image versions through the registry.

**Starting point:** a working Phase 07 cluster with MetalLB, Envoy Gateway, cert-manager, Longhorn, Authentik, and the todo-app, all reachable through the Gateway over HTTPS with forward-auth protecting the services.

**What you build in this phase:**

| Artifact | Purpose |
|---|---|
| `apps/harbor/` | Helm wrapper that deploys Harbor (nginx, core, registry, portal, database, redis, jobservice) |
| Updated `apps/envoy-gateway/` | Adds `harbor.local` to the TLS certificate |
| Updated `apps/todo-app/` | Changes image repositories to pull from Harbor |
| `scripts/trust-harbor-ca.sh` | Installs the homelab CA so Docker, Helm, and k3s containerd trust Harbor |
| `scripts/push-images.sh` | Tags and pushes container images to Harbor |
| `scripts/publish-chart.sh` | Packages and publishes the todo-app Helm chart to Harbor OCI |

Compare your work with `solution/` when you are done.

---

## How it works

```
Developer (docker build → docker push)
     → harbor.local/todo/frontend:1.0.0
     → Envoy Gateway (TLS) → Harbor nginx → Registry (stores blobs)

kubelet (pod image pull)
     → containerd reads registries.yaml
     → HTTPS to harbor.local with trusted CA
     → Harbor nginx → Registry (serves blobs)
     → Pod starts with the private image
```

The key idea: **images are pushed to Harbor once and pulled from Harbor by every pod that needs them**. The Gateway terminates TLS using the same homelab CA as all other services. Docker and Helm authenticate to push; containerd pulls without credentials because the project is public.

Harbor is **not** protected by authentik forward-auth. Unlike Longhorn, Harbor has its own authentication system, the Core component handles login, token issuance, and API auth. Adding a `SecurityPolicy` would break the Docker registry API protocol, which uses HTTP-level token negotiation (`401 → GET /service/token → retry with Bearer`) instead of browser redirects.

---

## Step 1 - Prerequisites

```bash
# Cluster with Phase 07 running
kubectl get pods -n envoy-gateway
kubectl get pods -n longhorn
kubectl get pods -n authentik
kubectl get pods -n todo

# Gateway IP assigned
kubectl get svc -n envoy-gateway

# HTTPS working
curl -sk https://todo.local -o /dev/null -w "%{http_code}\n"
# Expected: 302 (redirect to authentik - forward-auth is active)

# Docker CLI available (needed to push images)
docker version
```

You will also need the todo-app images built locally. If you do not have them:

```bash
docker build -t frontend:1.0.0 ../../application/frontend
docker build -t backend:1.0.0 ../../application/backend
```

---

## Step 2 - Add `harbor.local` to the TLS certificate

Extend the existing TLS certificate to cover the new hostname.

Update `apps/envoy-gateway/templates/certificate.yaml`:

```yaml
spec:
  dnsNames:
    - todo.local
    - longhorn.local
    - authentik.local
    - harbor.local          # ← add this
```

Redeploy:

```bash
helm upgrade --install cluster-envoy-gateway ./apps/envoy-gateway \
  -f ./apps/envoy-gateway/values/prod-values.yaml \
  -n envoy-gateway --wait

kubectl get certificate -n envoy-gateway
# Expected: gateway-tls   True
```

Add `harbor.local` to `/etc/hosts` (same Gateway IP):

```
<GATEWAY-IP>  todo.local longhorn.local authentik.local harbor.local
```

---

## Step 3 - Create and deploy the Harbor chart

### 3a - Create the wrapper chart

Create the following directory structure:

The `apps/harbor/` directory contains `Chart.yaml` at the root, a `values/` subdirectory with `prod-values.yaml`, and a `templates/` subdirectory with `route.yaml`.

**`apps/harbor/Chart.yaml`**

```yaml
apiVersion: v2
name: harbor
description: Harbor private container registry (wrapper chart)
version: 0.1.0
dependencies:
  - name: harbor
    version: 1.19.2
    repository: https://helm.goharbor.io
```

Check the latest available version before using the one above:

```bash
helm repo add harbor https://helm.goharbor.io
helm search repo harbor/harbor --versions | head -5
```

**`apps/harbor/values/prod-values.yaml`**

The Harbor chart is a dependency named `harbor`, so all subchart values nest under the `harbor:` key:

```yaml
harbor:
  expose:
    type: clusterIP
    tls:
      enabled: false
    clusterIP:
      name: harbor
      ports:
        httpPort: 80

  externalURL: https://harbor.local

  harborAdminPassword: "change-me-via-set-string"
  secretKey: "change-me-16char"

  persistence:
    enabled: true
    persistentVolumeClaim:
      registry:
        storageClass: longhorn
        size: 5Gi
      jobservice:
        jobLog:
          storageClass: longhorn
          size: 1Gi
      database:
        storageClass: longhorn
        size: 1Gi
      redis:
        storageClass: longhorn
        size: 1Gi
      trivy:
        storageClass: longhorn
        size: 2Gi

  portal:
    replicas: 1
  core:
    replicas: 1
  jobservice:
    replicas: 1
  registry:
    replicas: 1
  nginx:
    replicas: 1
  trivy:
    enabled: false

  logLevel: warning

gatewayRoute:
  enabled: true
  hostname: "harbor.local"
  gateway:
    name: public-gateway
    namespace: envoy-gateway
  pathPrefix: /
  backendService: harbor
  backendPort: 80
```

> **Why `expose.type: clusterIP` with `tls.enabled: false`?** TLS terminates at Envoy Gateway, not at Harbor's nginx. Harbor listens on plain HTTP internally. The `clusterIP.name: harbor` field sets the Kubernetes Service name directly, it is **not** prefixed with the Helm release name.

> **Why `externalURL: https://harbor.local`?** Harbor uses this URL to generate Docker registry token URLs and redirect URLs. It must match the hostname that clients use from outside the cluster (after TLS termination at the Gateway). If this is wrong, `docker login` and `docker push` will fail with authentication errors.

> **Why `trivy.enabled: false`?** Trivy adds a vulnerability scanner that consumes significant resources. It is disabled here to keep the footprint small. You can enable it as an additional exercise.

**`apps/harbor/templates/route.yaml`**

An HTTPRoute for the Harbor UI and registry API at `harbor.local`:

```yaml
{{- if .Values.gatewayRoute.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: harbor-ui
spec:
  hostnames:
    - {{ .Values.gatewayRoute.hostname | quote }}
  parentRefs:
    - name: {{ .Values.gatewayRoute.gateway.name }}
      namespace: {{ .Values.gatewayRoute.gateway.namespace }}
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: {{ .Values.gatewayRoute.pathPrefix }}
      backendRefs:
        - name: {{ .Values.gatewayRoute.backendService }}
          port: {{ .Values.gatewayRoute.backendPort }}
{{- end }}
```

### 3b - Deploy Harbor

Create the namespace with the gateway label:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: harbor
  labels:
    expose-via-gateway: "true"
EOF
```

Install:

```bash
helm dependency update ./apps/harbor

helm upgrade --install cluster-harbor ./apps/harbor \
  -f ./apps/harbor/values/prod-values.yaml \
  --set-string "harbor.harborAdminPassword=<your-harbor-password>" \
  --set-string "harbor.secretKey=<your-16-char-key>" \
  -n harbor \
  --wait --timeout 5m
```

> **`secretKey` must be exactly 16 characters.** Generate one with `openssl rand -hex 8`. This key encrypts sensitive data stored in Harbor's database. Once set, do not change it, existing encrypted values would become unreadable.

Verify:

```bash
kubectl get pods -n harbor
# Expected: harbor-core, harbor-database, harbor-jobservice, harbor-nginx,
#           harbor-portal, harbor-redis, harbor-registry - all Running

kubectl get httproute -n harbor
# Expected: harbor-ui   ["harbor.local"]

kubectl get svc -n harbor
# Expected: harbor (ClusterIP, port 80)
```

Open `https://harbor.local` in your browser, the Harbor login page should appear. Log in with `admin` and the password you set.

---

## Step 4 - Configure CA trust

Before you can push images or have k3s pull from Harbor, every component must trust the homelab CA. There are three places the CA needs to be installed:

1. **System trust store**, so `curl`, `helm`, and other CLI tools work
2. **Docker daemon**, so `docker push` and `docker pull` work
3. **k3s containerd**, so pods can pull images from Harbor

### 4a - Extract the CA certificate

```bash
kubectl get secret homelab-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/homelab-ca.crt
```

### 4b - Install into the system trust store

```bash
sudo cp /tmp/homelab-ca.crt /usr/local/share/ca-certificates/homelab-ca.crt
sudo update-ca-certificates
```

Verify:

```bash
curl -s https://harbor.local/api/v2.0/health
# Expected: {"status":"healthy","components":[...]}
# If you get a TLS error, the CA was not installed correctly
```

### 4c - Install for Docker

```bash
sudo mkdir -p /etc/docker/certs.d/harbor.local
sudo cp /tmp/homelab-ca.crt /etc/docker/certs.d/harbor.local/ca.crt
```

Verify:

```bash
docker login harbor.local -u admin -p <your-harbor-password>
# Expected: Login Succeeded
```

### 4d - Configure k3s containerd

Create the k3s registry configuration:

```bash
sudo cp /tmp/homelab-ca.crt /etc/rancher/k3s/harbor-ca.crt

sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'EOF'
mirrors:
  harbor.local:
    endpoint:
      - "https://harbor.local"
configs:
  "harbor.local":
    tls:
      ca_file: "/etc/rancher/k3s/harbor-ca.crt"
EOF
```

Restart k3s to apply:

```bash
sudo systemctl restart k3s
```

Wait for the cluster to stabilize:

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl get pods -n harbor
# All pods should return to Running
```

> **Automating CA trust:** The solution includes `scripts/trust-harbor-ca.sh` that performs all four steps in one script. Run it with `sudo -E ./scripts/trust-harbor-ca.sh` (the `-E` flag preserves your `KUBECONFIG` environment variable so `kubectl` works under `sudo`).

---

## Step 5 - Create a Harbor project

Images in Harbor are organized into projects. Create one for the todo-app:

### Option A - Via the UI

1. Log in at `https://harbor.local` (admin / your password)
2. **Projects → New Project**
3. **Name:** `todo`
4. **Access Level:** check **Public** (so k3s can pull without credentials)
5. Click **OK**

### Option B - Via the API

```bash
curl -sk -u "admin:<your-harbor-password>" \
  -H "Content-Type: application/json" \
  -X POST "https://harbor.local/api/v2.0/projects" \
  -d '{"project_name":"todo","metadata":{"public":"true"}}'
# Expected: HTTP 201 (Created) or 409 (already exists)
```

Verify:

```bash
curl -sk "https://harbor.local/api/v2.0/projects" | grep -o '"name":"todo"'
# Expected: "name":"todo"
```

---

## Step 6 - Build, tag, and push images to Harbor

### 6a - Tag the images

The images need to be tagged with the Harbor hostname and project:

```bash
docker tag frontend:1.0.0 harbor.local/todo/frontend:1.0.0
docker tag backend:1.0.0 harbor.local/todo/backend:1.0.0
```

### 6b - Push to Harbor

```bash
docker push harbor.local/todo/frontend:1.0.0
docker push harbor.local/todo/backend:1.0.0
```

Verify in the Harbor UI: go to **Projects → todo**, you should see `frontend` and `backend` repositories, each with the `1.0.0` tag.

Or via the API:

```bash
curl -sk "https://harbor.local/api/v2.0/projects/todo/repositories" | python3 -m json.tool
```

> **Automating pushes:** The solution includes `scripts/push-images.sh` that reads `IMAGE_TAG` and `HARBOR_ADMIN_PASSWORD` from `bootstrap/.env` and pushes both images. Run it with `./scripts/push-images.sh`.

---

## Step 7 - Update todo-app to pull from Harbor

Now that the images are in Harbor, update the todo-app values to reference them.

Update `apps/todo-app/values/prod-values.yaml`:

```yaml
frontend:
  image:
    repository: harbor.local/todo/frontend    # ← was: frontend
    tag: "1.0.0"

backend:
  image:
    repository: harbor.local/todo/backend     # ← was: backend
    tag: "1.0.0"
```

Redeploy:

```bash
helm upgrade --install my-app <chart-path> \
  -f ./apps/todo-app/values/prod-values.yaml \
  -n todo --wait
```

Verify the pods are pulling from Harbor:

```bash
kubectl get pods -n todo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
# Expected:
#   harbor.local/todo/frontend:1.0.0
#   harbor.local/todo/backend:1.0.0
```

Check that the app still works:

```bash
curl -sk https://todo.local -o /dev/null -w "%{http_code}\n"
# Expected: 302 (authentik redirect) or 200 (if you have a session)
```

---

## Step 8 - Verify

```bash
# All Harbor pods running
kubectl get pods -n harbor
# Expected: 7 pods - core, database, jobservice, nginx, portal, redis, registry - all Running

# Harbor service
kubectl get svc -n harbor
# Expected: harbor (ClusterIP, port 80)

# HTTPRoute present
kubectl get httproute -n harbor
# Expected: harbor-ui   ["harbor.local"]

# TLS certificate includes harbor.local
kubectl get certificate -n envoy-gateway -o yaml | grep -A6 dnsNames
# Expected: todo.local, longhorn.local, authentik.local, harbor.local

# Harbor API healthy
curl -sk https://harbor.local/api/v2.0/health | grep -o '"status":"healthy"'
# Expected: "status":"healthy"

# Project exists
curl -sk https://harbor.local/api/v2.0/projects/todo | grep -o '"name":"todo"'

# Images in registry
curl -sk https://harbor.local/v2/todo/frontend/tags/list
# Expected: {"name":"todo/frontend","tags":["1.0.0"]}

curl -sk https://harbor.local/v2/todo/backend/tags/list
# Expected: {"name":"todo/backend","tags":["1.0.0"]}

# todo-app pods using Harbor images
kubectl get pods -n todo -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n'
# Expected: harbor.local/todo/frontend:1.0.0  harbor.local/todo/backend:1.0.0

# todo-app still accessible
curl -sk https://todo.local -o /dev/null -w "%{http_code}\n"
# Expected: 302 (authentik redirect)
```

---

## Troubleshooting checklist

- **Harbor pods stuck in Pending**, all PVCs require the `longhorn` StorageClass. Check that Longhorn is running: `kubectl get pods -n longhorn`. If PVCs are stuck, check `kubectl get pvc -n harbor` and `kubectl describe pvc <name> -n harbor`.

- **`x509: certificate signed by unknown authority` on `docker push`**, the homelab CA is not trusted by Docker. Verify `/etc/docker/certs.d/harbor.local/ca.crt` exists and contains the correct certificate. If using Docker Desktop or Rancher Desktop, the daemon runs in a separate VM/distro and may need its own CA configuration.

- **`x509: certificate signed by unknown authority` on `docker login`**, same root cause. Also check the system trust store: `update-ca-certificates` must have been run after placing the CA in `/usr/local/share/ca-certificates/`.

- **Pods stuck in `ImagePullBackOff` with `tls: failed to verify certificate`**, k3s containerd does not trust the CA. Verify `/etc/rancher/k3s/registries.yaml` exists with the correct `ca_file` path, and that k3s was restarted after creating it. Check with `sudo systemctl restart k3s`.

- **`helm push` fails with TLS error**, Helm uses the system trust store. Ensure `update-ca-certificates` was run. Verify with `curl https://harbor.local/api/v2.0/health` (no `-k` flag), if this fails, the system trust store is not configured.

- **Harbor API returns 502 or connection refused**, Harbor components may still be starting. Check pod status: `kubectl get pods -n harbor`. Core, database, and redis must all be Running before the API responds. Typical startup time is 2–3 minutes.

- **`docker push` returns `unauthorized: authentication required`**, run `docker login harbor.local` first. Also verify the project exists in Harbor (the push target must be `harbor.local/<project>/<image>:<tag>`, if the project name is wrong, Harbor rejects the push).

- **Harbor service name is not `harbor`**, the `expose.clusterIP.name` field in values must be set to `harbor`. Without it, the service name will be derived from the Helm release name (e.g., `cluster-harbor-harbor-nginx`), and the HTTPRoute will not find the backend.

- **After k3s restart, pods stuck in ContainerCreating**, check if `/run/flannel/subnet.env` exists. The `k3s-killall.sh` script (sometimes triggered during restarts) removes this file. Recreate it manually if missing:
  ```bash
  sudo mkdir -p /run/flannel
  sudo tee /run/flannel/subnet.env > /dev/null <<'EOF'
  FLANNEL_NETWORK=10.42.0.0/16
  FLANNEL_SUBNET=10.42.0.1/24
  FLANNEL_MTU=1450
  FLANNEL_IPMASQ=true
  EOF
  ```

- **Longhorn volumes fail to mount after k3s restart**, if you see `not a shared mount` errors in Longhorn manager logs, run `sudo mount --make-rshared /` and restart the affected pods.

---

## Additional exercises

1. **Enable Trivy vulnerability scanning**, set `harbor.trivy.enabled: true` in the Harbor values, redeploy, and push an image. Check the scan results in the Harbor UI under the image's tag. Try pushing an image with known CVEs (e.g., an old `node:14` image) and review the report.

2. **Publish the Helm chart to Harbor OCI**, use `scripts/publish-chart.sh` to package and push the todo-app chart to `oci://harbor.local/todo/todo-app`. Then update `bootstrap/.env` to set `TODO_APP_CHART=oci://harbor.local/todo/todo-app` and redeploy the app from the OCI registry instead of the local chart directory:
   ```bash
   helm upgrade --install my-app oci://harbor.local/todo/todo-app \
     --version 0.1.0 \
     -f ./apps/todo-app/values/prod-values.yaml \
     -n todo --wait
   ```

3. **Version control workflow**, simulate a new release:
   1. Modify the frontend (e.g., change the page title in `application/frontend/`)
   2. Rebuild with a new tag: `docker build -t frontend:1.1.0 ./application/frontend`
   3. Tag and push to Harbor: `docker tag frontend:1.1.0 harbor.local/todo/frontend:1.1.0 && docker push harbor.local/todo/frontend:1.1.0`
   4. Deploy the new version: `helm upgrade my-app <chart> -n todo --set frontend.image.tag=1.1.0`
   5. Verify the new version is running, then roll back: `helm upgrade my-app <chart> -n todo --set frontend.image.tag=1.0.0`
   6. Confirm both versions remain available in Harbor (Projects → todo → frontend → Tags)

4. **Private project with imagePullSecrets**, create a second Harbor project as **private**. Push an image to it. Create a Kubernetes Secret of type `kubernetes.io/dockerconfigjson` in the `todo` namespace and reference it in the Deployment's `imagePullSecrets`. Verify that pods can pull from the private project only when the secret is present.

5. **Robot accounts**, create a robot account in Harbor with pull-only permissions on the `todo` project. Use its token in `registries.yaml` instead of the admin password. Verify that `docker push` fails with the robot account but `docker pull` succeeds.

6. **Pull-through cache**, configure Harbor as a [proxy cache](https://goharbor.io/docs/2.12.0/administration/configure-proxy-cache/) for Docker Hub. Create a proxy project, then pull a public image through Harbor (`harbor.local/dockerhub-proxy/library/nginx:latest`). The first pull fetches from Docker Hub; subsequent pulls are served from Harbor's local cache.

---

## Success criteria

- `apps/harbor/` wrapper chart installed; core, database, jobservice, nginx, portal, redis, and registry pods are Running
- `harbor` Service exists with `ClusterIP` on port 80
- `harbor.local` is reachable via the Gateway over HTTPS and shows the Harbor login page
- TLS certificate includes `harbor.local` in `dnsNames`
- k3s containerd is configured to trust the homelab CA via `/etc/rancher/k3s/registries.yaml`
- Harbor project `todo` exists and is set to public
- Container images `harbor.local/todo/frontend:1.0.0` and `harbor.local/todo/backend:1.0.0` are pushed and visible in Harbor
- todo-app pods reference `harbor.local/todo/frontend:1.0.0` and `harbor.local/todo/backend:1.0.0`
- The application is functional, `https://todo.local` loads after authenticating through authentik
