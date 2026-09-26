# Phase 06 - Routing and Traffic Exposure with Envoy Gateway

This phase centralizes all external traffic through a single, policy-controlled entry point. You will install MetalLB to give the cluster a real external IP on bare metal, install Envoy Gateway to implement the Kubernetes Gateway API, add HTTPRoutes for the todo-app and Longhorn UI, then complete the setup with cert-manager for automatic TLS.

**What you build in this phase:**

| Artifact | Purpose |
|---|---|
| `apps/metallb/` | Helm wrapper that assigns real IPs to `LoadBalancer` services on bare metal |
| `apps/envoy-gateway/` | Helm wrapper that installs the Gateway API control plane and creates `GatewayClass` + `Gateway` |
| `apps/cert-manager/` | Helm wrapper that automates TLS certificate issuance and renewal |
| Updated `apps/longhorn/` | Enables the Longhorn UI `HTTPRoute` via `gatewayRoute.enabled: true` |
| `application/chart/` | Canonical todo-app Helm chart; Phase 06 references it through `solution/apps/todo-app` |
| Updated todo-app chart | Adds an `HTTPRoute` and a Helm hook that creates the PostgreSQL Secret in-cluster if it does not already exist |

Compare your work with `solution/` when you are done.

---

## How it works

```
MetalLB assigns 192.168.1.200 to the Envoy Gateway LoadBalancer service
     ↓
/etc/hosts (homelab) or DNS resolves todo.local → 192.168.1.200
     ↓
Client connects to 192.168.1.200:80 (HTTP) or :443 (HTTPS)
     ↓
Envoy Proxy matches the request against HTTPRoutes by hostname and path
     ↓
HTTPRoute for longhorn.local → longhorn-frontend:80
HTTPRoute (catch-all) → my-app-todo-app-frontend:3000
     ↓
cert-manager renews TLS certificates automatically before expiry
```

The key idea: **one IP, one port, all services separated by hostname**. MetalLB provides the IP, Envoy Gateway routes by hostname, cert-manager keeps TLS current.

---

## Step 1 - Prerequisites

```bash
# Cluster nodes Ready
kubectl get nodes

# Helm available
helm version --short

# Phase 05 todo-app is running
kubectl get pods -n todo
```

Decide which IP range MetalLB may assign from your LAN. The range must be on the same subnet as your nodes but **not** served by your router's DHCP. A small range like `.200–.210` is enough for a homelab.

```bash
# Confirm node IPs so you can pick a non-overlapping range
kubectl get nodes -o wide
```

Write down the range, you will use it in Step 2.

---

## Step 2 - Install MetalLB

Create the following directory structure:

The `apps/metallb/` directory contains a `Chart.yaml` at the root, a `values/` folder with `prod-values.yaml`, and a `templates/` folder with two templates: `ipaddresspool.yaml` and `l2advertisement.yaml`.

**`apps/metallb/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-metallb
description: MetalLB bare-metal load balancer
type: application
version: 1.0.0
dependencies:
  - name: metallb
    version: 0.15.3
    repository: https://metallb.github.io/metallb
```

**`apps/metallb/values/prod-values.yaml`**

```yaml
metallb: {}
```

MetalLB's upstream chart has no values worth overriding for a homelab. The address pool is managed via custom resources in the templates below.

**`apps/metallb/templates/ipaddresspool.yaml`**

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  addresses:
    - 192.168.1.200-192.168.1.210   # adjust to your LAN
```

**`apps/metallb/templates/l2advertisement.yaml`**

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-advertisement
  namespace: metallb-system
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  ipAddressPools:
    - local-pool
```

> **Why Helm hooks on the CRs?** MetalLB's CRDs come from a subchart, and Helm does not guarantee subchart CRDs are registered before the parent chart's templates are applied. Without the hook annotations, Helm tries to create `IPAddressPool` while the CRD doesn't exist yet and fails with "no matches for kind". The `post-install,post-upgrade` hook tells Helm to apply these resources only after the main release is fully deployed (and `--wait` ensures MetalLB is running and its CRDs are established before that point). `before-hook-creation` deletes the old hook resource before each upgrade so there is no conflict on re-runs.

> **Why Layer 2?** In Layer 2 mode MetalLB answers ARP requests for each assigned IP from the elected node. No router configuration is needed, any host on the same LAN segment can reach the IP immediately. BGP mode is more scalable but requires a BGP-capable router.

**Install MetalLB:**

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm dependency update ./apps/metallb

helm upgrade --install cluster-metallb ./apps/metallb \
  -f ./apps/metallb/values/prod-values.yaml \
  -n metallb-system \
  --create-namespace

kubectl rollout status deploy/cluster-metallb-metallb-controller -n metallb-system
kubectl get ipaddresspool -n metallb-system
# Expected: local-pool   ...   true
```

MetalLB is ready. Any `LoadBalancer` service you create from this point will receive an IP from the pool.

---

## Step 3 - Install Envoy Gateway

Create the following directory structure:

The `apps/envoy-gateway/` directory contains a `Chart.yaml` at the root, a `values/` folder with `prod-values.yaml`, and a `templates/` folder with `gateway.yaml`.

**`apps/envoy-gateway/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-envoy-gateway
description: Envoy Gateway, Kubernetes Gateway API implementation
type: application
version: 1.0.0
dependencies:
  - name: gateway-helm
    version: 1.6.4
    repository: oci://docker.io/envoyproxy
```

**`apps/envoy-gateway/values/prod-values.yaml`**

```yaml
gateway-helm: {}
```

**`apps/envoy-gateway/templates/gateway.yaml`**

Both the `GatewayClass` and the `Gateway` live in a single file, separated by `---`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: envoy-gateway
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              expose-via-gateway: "true"
```

> **Why `Selector` instead of `All`?** With `from: All` any namespace in the cluster can attach an HTTPRoute to this Gateway, a misconfigured or compromised namespace could start routing traffic through the public entry point. `Selector` restricts attachment to namespaces that carry a specific label (`expose-via-gateway: "true"`). Only `todo` and `longhorn` get that label, so they are the only namespaces that can expose services externally. Any other namespace is silently excluded regardless of what HTTPRoutes it creates. This is the recommended approach even in development clusters, it makes the access boundary explicit and visible.

**Install Envoy Gateway:**

```bash
helm dependency update ./apps/envoy-gateway

helm upgrade --install cluster-envoy-gateway ./apps/envoy-gateway \
  -f ./apps/envoy-gateway/values/prod-values.yaml \
  -n envoy-gateway \
  --create-namespace

kubectl rollout status deploy/envoy-gateway -n envoy-gateway
kubectl get gatewayclass envoy
# Expected: envoy   gateway.envoyproxy.io/gatewayclass-controller   Accepted   ...
```

After a few seconds, Envoy Gateway creates an Envoy Proxy deployment and a `LoadBalancer` service. MetalLB assigns it an IP:

```bash
kubectl get svc -n envoy-gateway
# Expected: envoy-envoy-gateway-...   LoadBalancer   ...   192.168.1.200   80:...
```

Record that IP, you will add it to `/etc/hosts` in the next step.

---

## Step 4 - Add the todo-app HTTPRoute

Because the Gateway uses `from: Selector`, the `todo` namespace must carry the `expose-via-gateway: "true"` label before any HTTPRoute inside it can attach:

```bash
kubectl label namespace todo expose-via-gateway=true
```

The solution's `bootstrap.sh` creates namespaces with the label already applied. If you prefer a declarative approach, you can add a `Namespace` resource to your chart templates, but the canonical chart does not manage namespace creation, it is left to the bootstrap or the operator.

In the canonical chart, create `application/chart/templates/frontend/route.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "todo-app.fullname" . }}-frontend
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "todo-app.labels" . | nindent 4 }}
spec:
  parentRefs:
    - name: public-gateway
      namespace: envoy-gateway
  rules:
    - backendRefs:
        - name: {{ include "todo-app.fullname" . }}-frontend
          port: 3000
      matches:
        - path:
            type: PathPrefix
            value: /
```

No hostname filter here, this route matches any request that no other HTTPRoute claims. The Longhorn route in the next step uses a hostname filter, so it wins over this one for `longhorn.local` traffic.

> **Forward-auth is wired but disabled in this phase.** The canonical chart also ships `frontend/security-policy.yaml`, an Envoy Gateway `SecurityPolicy` that puts forward-auth (ext-auth) in front of this same HTTPRoute. It only renders when **both** `frontend.gatewayRoute.enabled` and `frontend.auth.enabled` are true. This phase keeps `frontend.auth.enabled: false`, so the route serves unauthenticated traffic, the SecurityPolicy is **prepared for Phase 07**, where authentik is added and `auth.enabled` is flipped to `true` to protect the frontend. Nothing about auth is exercised here; only the plain HTTPRoute is tested.

**Redeploy the todo-app:**

```bash
helm upgrade --install my-app ./apps/todo-app \
  -f ./apps/todo-app/values/prod-values.yaml \
  -n todo
```

In the solution, `apps/todo-app` is a reference to `../../../application/chart`. The real chart source lives in `application/chart`, and that is the chart you package and publish.

The canonical chart creates `todo-db-secret` with a `pre-install,pre-upgrade` Helm hook when no `postgres.existingSecret` is configured. If the Secret already exists, the hook leaves it unchanged so upgrades do not rotate database credentials accidentally.

The password contract is intentionally simple:

- Omit `postgres.bootstrap.credentials.password`, or leave it empty in an override file, to generate one alphanumeric password in-cluster.
- Set `postgres.bootstrap.credentials.password` only when you need deterministic credentials for CI, restore, or a repeatable lab setup.
- Keep `user`, `password`, and `database` URI-safe (`A-Z a-z 0-9 . _ ~ -`) because the chart builds `DATABASE_URI` without percent-encoding.

### (Optional preview) Publish the todo-app chart to OCI

By default the solution bootstrap deploys the canonical `application/chart` straight from disk (local), so this phase needs no registry. This section is an **optional preview** of the OCI workflow: Docker Hub acts as a temporary registry now, and Phase 08 swaps it for a self-hosted Harbor by pointing the same `CHART_REGISTRY` variable at the Harbor domain. OCI only becomes the real deploy path once Harbor (Phase 08) and ArgoCD (Phase 09) exist.

```bash
cd phases/06-routing-and-traffic-exposure/solution
cp bootstrap/.env.example bootstrap/.env
# Edit DOCKERHUB_USER, IMAGE_TAG, and optionally CHART_REGISTRY/CHART_VERSION.

helm registry login registry-1.docker.io \
  --username <dockerhub-user>

./scripts/publish-chart.sh
```

The published chart is then installable with:

```bash
helm upgrade --install my-app \
  oci://registry-1.docker.io/<dockerhub-user>/todo-app \
  --version 0.1.0 \
  -f ./apps/todo-app/values/prod-values.yaml \
  -n todo
```

To make the bootstrap consume that published chart instead of the local one, set
`TODO_APP_CHART=oci://registry-1.docker.io/${DOCKERHUB_USER}/todo-app` in `bootstrap/.env`.
Leaving `TODO_APP_CHART=local` (the default) keeps the phase self-contained.

**Add a hosts entry on your workstation** (replace `192.168.1.200` with the IP from Step 3):

```
# /etc/hosts
192.168.1.200  todo.local
```

Open `http://todo.local` in your browser, the todo-app should load.

---

## Step 5 - Enable the Longhorn UI route

The `longhorn` namespace also needs the `expose-via-gateway: "true"` label:

```bash
kubectl label namespace longhorn expose-via-gateway=true
```

As with the `todo` namespace, the solution's `bootstrap.sh` creates the namespace with both the Pod Security Admission labels and the gateway label already applied.

The Longhorn wrapper chart already has an `HTTPRoute` template guarded by a flag. Enable it by updating `apps/longhorn/values/prod-values.yaml`:

```yaml
gatewayRoute:
  enabled: true
  gateway:
    name: public-gateway
    namespace: envoy-gateway
  hostname: "longhorn.local"
  pathPrefix: /
```

**Add a hosts entry** (same IP as above):

```
192.168.1.200  longhorn.local
```

**Redeploy Longhorn:**

```bash
helm upgrade --install cluster-longhorn ./apps/longhorn \
  -f ./apps/longhorn/values/prod-values.yaml \
  -n longhorn
```

Verify routing:

```bash
kubectl get httproute -A
# Both routes should appear: longhorn-ui (longhorn ns) and the todo route (todo ns)

kubectl describe httproute longhorn-ui -n longhorn
# Status.Parents should show Accepted: True
```

Open `http://longhorn.local`, the Longhorn UI should load. Open `http://todo.local`, the todo-app should still work.

---

## Step 6 - Install cert-manager

cert-manager is split into two separate Helm releases: the controller (which installs the CRDs and runs the cert-manager pods) and the issuers (which create `ClusterIssuer` and `Certificate` resources that depend on those CRDs). The issuers must be installed **after** the CRDs are established, bundling them into the same chart would fail because Helm would try to apply `ClusterIssuer` resources before the CRD is registered.

### 6a - Install the cert-manager controller

The `apps/cert-manager/` directory contains a `Chart.yaml` at the root and a `values/` folder with `prod-values.yaml`.

**`apps/cert-manager/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-cert-manager
description: cert-manager, automatic TLS certificate management
type: application
version: 1.0.0
dependencies:
  - name: cert-manager
    version: v1.20.1
    repository: oci://quay.io/jetstack/charts
```

**`apps/cert-manager/values/prod-values.yaml`**

```yaml
cert-manager:
  crds:
    enabled: true
```

> **Why `crds.enabled: true`?** cert-manager ships its CRDs separately from the chart. This value installs them as part of `helm upgrade --install` so `Certificate` and `ClusterIssuer` resources are available immediately after install.

```bash
helm dependency update ./apps/cert-manager

helm upgrade --install cluster-cert-manager ./apps/cert-manager \
  -f ./apps/cert-manager/values/prod-values.yaml \
  -n cert-manager \
  --create-namespace

kubectl rollout status deploy/cluster-cert-manager-cert-manager -n cert-manager
```

### 6b - Install the CA issuers

Once the cert-manager CRDs are established, install the issuers as a separate chart:

The `apps/cert-manager-issuers/` directory contains a `Chart.yaml` at the root and a `templates/` folder with `selfsigned-cluster-issuer.yaml`.

**`apps/cert-manager-issuers/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-cert-manager-issuers
type: application
version: 1.0.0
```

For a homelab without a public domain, a self-signed CA is the right choice. You create a root CA and use it to sign all service certificates. This requires three resources because cert-manager cannot issue a CA certificate without an issuer, and the issuer backing the CA cannot exist until the CA Secret is written:

**`apps/cert-manager-issuers/templates/selfsigned-cluster-issuer.yaml`**

```yaml
---
# Step 1: bootstrap issuer - signs its own certificates to create the CA
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-root
spec:
  selfSigned: {}
---
# Step 2: homelab root CA certificate, issued by the self-signed bootstrapper
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: homelab-ca
  secretName: homelab-ca-secret
  issuerRef:
    name: selfsigned-root
    kind: ClusterIssuer
---
# Step 3: cluster-wide issuer backed by the homelab CA - use this in Certificate resources
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: homelab-ca
spec:
  ca:
    secretName: homelab-ca-secret
```

> **Self-signed vs Let's Encrypt:** Let's Encrypt requires a publicly reachable domain and an ACME challenge (HTTP-01 or DNS-01). For homelab `.local` hostnames this is not possible, use the self-signed CA instead. If you have a public domain, replace `homelab-ca` with an ACME `ClusterIssuer` pointing at `https://acme-v02.api.letsencrypt.org/directory`.

```bash
helm upgrade --install cluster-cert-manager-issuers ./apps/cert-manager-issuers \
  -n cert-manager

kubectl get clusterissuer
# Expected: homelab-ca   True   ...
#           selfsigned-root   True   ...
```

---

## Step 7 - Add HTTPS to the Gateway

### 7a - Request a certificate

Create `apps/envoy-gateway/templates/certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-tls
  namespace: envoy-gateway
spec:
  secretName: gateway-tls-secret
  issuerRef:
    name: homelab-ca
    kind: ClusterIssuer
  dnsNames:
    - todo.local
    - longhorn.local
```

cert-manager issues the certificate and writes it into `gateway-tls-secret` in the `envoy-gateway` namespace.

### 7b - Add an HTTPS listener to the Gateway

Update `apps/envoy-gateway/templates/gateway.yaml` to add a second listener:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: envoy-gateway
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              expose-via-gateway: "true"
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: gateway-tls-secret
            namespace: envoy-gateway
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              expose-via-gateway: "true"
```

**Redeploy:**

```bash
helm upgrade --install cluster-envoy-gateway ./apps/envoy-gateway \
  -f ./apps/envoy-gateway/values/prod-values.yaml \
  -n envoy-gateway
```

Wait for the certificate to be issued:

```bash
kubectl get certificate -n envoy-gateway
# Expected: gateway-tls   True   gateway-tls-secret   ...
```

Open `https://todo.local`, the browser will warn about the self-signed CA. Add a security exception, or import the CA certificate into your browser's trust store to clear the warning permanently:

```bash
# Export the CA cert
kubectl get secret homelab-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt

# Linux
sudo cp homelab-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot homelab-ca.crt
```

---

## Step 8 - Verify

```bash
# All gateway-related pods running
kubectl get pods -n envoy-gateway
kubectl get pods -n metallb-system
kubectl get pods -n cert-manager

# Gateway has an external IP from MetalLB
kubectl get svc -n envoy-gateway
# Expected: LoadBalancer ... 192.168.1.200

# Both HTTPRoutes accepted
kubectl get httproute -A
kubectl describe httproute -A | grep -A5 "Status"

# Certificate issued and ready
kubectl get certificate -n envoy-gateway
# Expected: READY=True

# HTTP works
curl -I http://todo.local
# Expected: HTTP/1.1 200 OK

# HTTPS works (use --cacert or -k to skip verification)
curl -I --cacert homelab-ca.crt https://todo.local
# Expected: HTTP/1.1 200 OK
```

---

## Troubleshooting checklist

- `helm upgrade` fails with `no matches for kind "IPAddressPool"`, the `IPAddressPool` or `L2Advertisement` templates are missing the `helm.sh/hook` annotations; Helm tries to apply them before MetalLB's CRDs are registered
- `kubectl get ipaddresspool -n metallb-system` shows nothing after install, hook annotations are correct but `--wait` was not used; the controller had not finished starting when the hooks ran; rerun `helm upgrade --install ... --wait`
- `LoadBalancer` service in `envoy-gateway` stays `<pending>`, MetalLB is not installed, or the IP range overlaps with DHCP; check speaker logs: `kubectl logs -n metallb-system -l app.kubernetes.io/component=speaker`
- `GatewayClass` not `Accepted`, Envoy Gateway control plane not running; check `kubectl logs deploy/envoy-gateway -n envoy-gateway`
- HTTPRoute status shows `NotAllowedByListeners`, the namespace is missing the `expose-via-gateway: "true"` label; add it with `kubectl label namespace <ns> expose-via-gateway=true` and redeploy the chart
- HTTPRoute status shows `NotResolvedRefs`, the backend Service name or port does not match what is deployed; `kubectl describe httproute <name> -n <ns>`
- `http://todo.local` resolves but returns 404, HTTPRoute is attached but the hostname or path does not match; check `kubectl get httproute -A -o yaml`
- Certificate stuck in `False`, inspect with `kubectl describe certificate -n envoy-gateway` and `kubectl describe certificaterequest -n envoy-gateway`; common cause is missing CRDs or `ClusterIssuer` not Ready
- Browser rejects HTTPS with self-signed warning, expected; import `homelab-ca.crt` into your browser trust store or use `curl -k` for quick testing
- `helm upgrade` fails pulling `oci://registry-1.docker.io/<user>/todo-app`, publish the chart with `./scripts/publish-chart.sh`, confirm `CHART_VERSION` matches `application/chart/Chart.yaml`, and run `helm registry login` for private repositories

---

## Additional exercises

1. **Route precedence test**, add a second HTTPRoute in the `todo` namespace that matches `todo.local` with an exact path `/test`. Confirm it wins over the prefix `/` route for that path only.
2. **Hostname isolation**, add a third fake service and HTTPRoute for `other.local`. Confirm `http://todo.local` and `http://other.local` reach different backends without touching each other's routes.
3. **Certificate renewal simulation**, patch the `Certificate` resource to set a very short `duration` and `renewBefore`. Watch cert-manager automatically renew it without any manual intervention.
4. **BGP exploration**, if you have a router that supports BGP (e.g., VyOS or OPNsense), switch MetalLB to BGP mode and observe how routes appear in the router's routing table.
5. **Label removal test**, remove the `expose-via-gateway: "true"` label from the `longhorn` namespace (`kubectl label namespace longhorn expose-via-gateway-`). Watch the Longhorn HTTPRoute transition to `NotAllowedByListeners`. Re-add the label and confirm recovery without redeploying anything.
6. **Let's Encrypt staging**, if you have a public domain, create a second `ClusterIssuer` pointing at the Let's Encrypt staging endpoint and issue a certificate. Observe the ACME challenge flow in the cert-manager logs.

---

## Success criteria

- `apps/metallb/` wrapper chart installed; `IPAddressPool` exists and MetalLB pods are Running
- `apps/envoy-gateway/` wrapper chart installed; `GatewayClass` is `Accepted`
- Envoy Gateway `LoadBalancer` service has an external IP assigned by MetalLB
- `Gateway` resource has HTTP (port 80) and HTTPS (port 443) listeners, both using `from: Selector`
- `todo` namespace has label `expose-via-gateway: "true"`; `application/chart` has an `HTTPRoute` attached to the Gateway; `http://todo.local` loads the app
- `application/chart` has chart `version: 0.1.0`, can be pushed to OCI with `solution/scripts/publish-chart.sh`, and the bootstrap can consume it from `CHART_REGISTRY`
- `longhorn` namespace has label `expose-via-gateway: "true"`; `apps/longhorn/` has `gatewayRoute.enabled: true`; `http://longhorn.local` loads the Longhorn UI
- `apps/cert-manager/` wrapper chart installed; `homelab-ca` `ClusterIssuer` is `Ready`
- `Certificate` in the `envoy-gateway` namespace is `READY=True`
- `https://todo.local` and `https://longhorn.local` are reachable (with CA trust or `-k`)
