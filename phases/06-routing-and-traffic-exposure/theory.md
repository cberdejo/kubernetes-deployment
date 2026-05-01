# Phase 06 Routing and Traffic Exposure

Previous phases exposed services using `NodePort`, which is enough for a single development cluster but breaks down in any realistic setup. `NodePort` opens raw high-numbered ports (30000–32767) on every node, which means users must know which port each service lives on, TLS termination is your own problem to solve, and there is no mechanism for path-based routing, header matching, or traffic policy of any kind. As the number of services grows, managing a patchwork of `NodePort` assignments becomes fragile and hard to reason about.

This phase replaces that approach with the **Kubernetes Gateway API**, implemented by **Envoy Gateway**. **MetalLB** gives the Gateway's `LoadBalancer` service a real IP on bare metal (where no cloud provider exists), and **cert-manager** automates TLS certificate issuance and renewal so HTTPS works without manual certificate management. By the end of the phase, all external traffic enters the cluster through a single, policy-controlled entry point with automatic HTTPS.

**Core concepts to master in this phase:**
- **NodePort and its limitations**, why it is insufficient beyond basic development
- **Kubernetes Ingress**, what it does and why the Gateway API supersedes it
- **GatewayClass / Gateway / HTTPRoute**, the three-tier model of the Gateway API
- **Envoy Gateway**, how the control plane translates Gateway API objects into Envoy xDS configuration
- **Route matching and precedence**, how conflicts between HTTPRoutes are resolved
- **Hostname-based routing**, separating traffic for different services on the same port
- **MetalLB**, how bare metal clusters get real `LoadBalancer` IPs using ARP or BGP
- **cert-manager**, how TLS certificates are issued, stored, and renewed automatically

---

## How Traffic Was Exposed Before

Kubernetes has three main Service types and a legacy traffic routing mechanism, each with different tradeoffs.

### ClusterIP

A virtual IP internal to the cluster. Pods can reach it; nothing outside the cluster can. This is what every backend and database uses. The entry point must be something else.

### NodePort

Exposes a Service on a static port (30000–32767) on every node's IP address. Traffic to `<NodeIP>:<NodePort>` is forwarded to the Service's backend Pods.

```
User browser
     ↓
http://192.168.1.10:30080  (NodeIP:NodePort)
     ↓
kube-proxy / iptables rule
     ↓
frontend Pod
```

It works, but the problems compound quickly:
- Non-standard ports; users and DNS entries must include the port number.
- No URL routing. Every Service gets its own port; there is no way to distinguish `todo.local/` from `longhorn.local/` on the same port.
- No TLS termination. You handle certificates yourself, per service.
- All nodes expose the port, even nodes that run no relevant pods (kube-proxy handles the forwarding regardless).
- The port range is limited and shared cluster-wide.

### LoadBalancer

Creates an external load balancer (on cloud providers) that forwards to the Service. Fixes the non-standard port problem — you get a real IP on port 80 — but each Service gets its own load balancer. That is expensive and still provides no routing logic. On bare metal clusters there is no cloud control plane, so `LoadBalancer` services stay in `<pending>` forever — MetalLB fills this gap (covered below).

### Ingress (the predecessor to Gateway API)

Ingress was the Kubernetes answer to this: a single resource that declares HTTP routing rules, backed by a controller (nginx, Traefik, etc.) that reads those rules and configures itself.

```
User browser
     ↓
Ingress controller (nginx, Traefik, ...)
     ↓
Routing rule: /api/* → backend-service
Routing rule: /*     → frontend-service
```

This works, but Ingress has a fundamental design flaw: the spec only covers basic path and host routing. Everything else — TLS options, rate limiting, authentication, redirect behavior — is implemented via **controller-specific annotations**. The annotations for nginx are different from Traefik, which are different from HAProxy. If you switch controllers, you rewrite all your routing configuration.

---

## The Kubernetes Gateway API

The Gateway API is the official successor to Ingress. It was designed from the start to avoid the annotation problem by modeling everything as typed Kubernetes resources with first-class spec fields. It is now stable (v1) as of Kubernetes 1.28.

The core insight is a **role-based three-tier model**:

```
GatewayClass  (cluster-scoped, created by infra admin)
     ↓
Gateway       (namespace-scoped, created by infra admin)
     ↓
HTTPRoute     (namespace-scoped, created by app developer)
     ↓
Service       (namespace-scoped, the actual Pods)
```

Each tier is owned by a different persona and has a different lifecycle.

### GatewayClass

A cluster-scoped resource that says: "there exists a type of Gateway managed by this controller." It is the bridge between the Gateway API spec and the actual implementation (Envoy Gateway, nginx Gateway Fabric, Istio, etc.).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

Only one `GatewayClass` per controller is typically needed cluster-wide.

### Gateway

A namespace-scoped resource that says: "listen on these ports for this protocol." Think of it as the actual load balancer or proxy instance.

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
          from: All
```

`allowedRoutes.namespaces.from: All` allows HTTPRoutes from any namespace to attach to this Gateway. In production you would restrict this to specific namespaces.

### HTTPRoute

A namespace-scoped resource that says: "for requests matching these rules, forward to this Service." App developers create HTTPRoutes; they do not touch the Gateway.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: todo-frontend
  namespace: todo
spec:
  parentRefs:
    - name: public-gateway
      namespace: envoy-gateway
  rules:
    - backendRefs:
        - name: my-app-todo-app-frontend
          port: 3000
      matches:
        - path:
            type: PathPrefix
            value: /
```

The `parentRefs` field is how the HTTPRoute attaches to a specific Gateway. Cross-namespace references are allowed because the Gateway has `allowedRoutes.namespaces.from: All`.

### Complete traffic flow

```
External request: GET http://192.168.1.10/
     ↓
Envoy proxy pod (port 80) — the Gateway's data plane
     ↓
Gateway API controller matches request against HTTPRoutes
     ↓
HTTPRoute rule: pathPrefix "/" → Service "my-app-todo-app-frontend:3000"
     ↓
frontend Pod (nginx)
     ↓
nginx proxies /api/v1/* → backend Service (ClusterIP, internal)
     ↓
backend Pod
```

The backend never needs its own HTTPRoute. The frontend nginx handles the proxy.

---

## Hostname-Based Routing

When multiple HTTPRoutes attach to the same Gateway on the same port, they need a way to not conflict with each other. The cleanest mechanism is **hostname matching**.

```yaml
# Longhorn UI route — only matches the "longhorn.local" hostname
spec:
  hostnames:
    - "longhorn.local"
  rules:
    - backendRefs:
        - name: longhorn-frontend
          port: 80
      matches:
        - path:
            type: PathPrefix
            value: /

# Todo-app route — no hostname filter, matches everything else
spec:
  rules:
    - backendRefs:
        - name: my-app-todo-app-frontend
          port: 3000
      matches:
        - path:
            type: PathPrefix
            value: /
```

With this setup:
- `http://longhorn.local/` → Longhorn UI
- `http://192.168.1.10/` → todo-app frontend

The client sends a `Host: longhorn.local` header (set automatically by the browser when using the hostname). The Gateway API controller matches on that header before checking path rules.

In a homelab you add entries to `/etc/hosts` on your workstation:

```
192.168.1.10  longhorn.local
```

In production you point DNS records at the Gateway's external IP.

### Route matching precedence

When more than one HTTPRoute could match a request, the Gateway API resolves conflicts in this order (most specific wins):

1. **Hostname match** beats no hostname match.
2. **Exact path** beats prefix path beats wildcard.
3. **Longer prefix** beats shorter prefix (e.g., `/api/v1` beats `/api`).
4. **Earlier creation time** breaks ties.

---

## Envoy Gateway

Envoy Gateway is a CNCF project that implements the Kubernetes Gateway API using **Envoy Proxy** as the data plane. It was started by the core Envoy maintainers and is now the reference implementation for production-grade Gateway API usage.

### What Envoy Proxy is

Envoy is a high-performance open-source proxy originally built at Lyft and donated to the CNCF. It is also the data plane used by Istio, AWS App Mesh, and many other service meshes and API gateways. Its key advantage is **dynamic configuration via xDS APIs** — the proxy can be reconfigured without restarts, which is essential in a Kubernetes environment where routes change constantly.

### Architecture

```
┌──────────────────────────────────────────┐
│  Kubernetes API Server                   │
│  (GatewayClass, Gateway, HTTPRoute objs) │
└────────────────┬─────────────────────────┘
                 │ watches
                 ▼
┌──────────────────────────────────────────┐
│  Envoy Gateway (control plane)           │
│  - Watches Gateway API resources         │
│  - Translates them to Envoy xDS config   │
│  - Pushes config to Envoy proxy via gRPC │
└────────────────┬─────────────────────────┘
                 │ xDS (dynamic config)
                 ▼
┌──────────────────────────────────────────┐
│  Envoy Proxy (data plane)                │
│  - Handles actual HTTP traffic           │
│  - LoadBalancer Service exposes port 80  │
│  - Created per Gateway resource          │
└──────────────────────────────────────────┘
```

Each `Gateway` resource you create causes Envoy Gateway to spin up a dedicated Envoy Proxy `Deployment` and a `Service` (typically `LoadBalancer` type) that exposes it. This is unlike nginx Ingress, where a single controller handles all ingress traffic. With Envoy Gateway you can have multiple Gateway instances for different purposes (public vs. internal, HTTP vs. gRPC).

### How Envoy Gateway is installed

Envoy Gateway is distributed as a Helm chart via OCI registry:

```
oci://docker.io/envoyproxy/gateway-helm
```

The chart installs the Envoy Gateway control plane (a `Deployment` in the target namespace). GatewayClass and Gateway resources are then created separately — in this phase, via a Helm wrapper chart that pins the version and keeps everything in Git.

---

## MetalLB

Cloud providers implement the `LoadBalancer` service type natively: create a `LoadBalancer` service and the cloud allocates a real IP and routes traffic to it automatically. On bare metal there is no cloud control plane. MetalLB runs inside the cluster and fills that role — it watches for `LoadBalancer` services and assigns IPs from a configured pool, announcing those IPs to the network using Layer 2 (ARP/NDP) or BGP.

This matters for this phase because Envoy Gateway creates a `LoadBalancer` service for each `Gateway` resource. Without MetalLB, that service stays `<pending>` and traffic never reaches the cluster.

### Layer 2 mode

MetalLB elects one node to "own" each service IP. That node responds to ARP requests for the IP, so any host on the same L2 network (same broadcast domain / same switch segment) can reach it. kube-proxy then forwards traffic internally to the actual pod.

```
Client (same LAN)
     ↓ ARP: who has 192.168.1.200?
MetalLB speaker on elected node: I do!
     ↓
kube-proxy → Envoy Proxy pod
```

The main limitation: all traffic funnels through the elected node. If that node goes down, MetalLB elects another, but existing connections drop — failover is not seamless. For a homelab this is acceptable.

### BGP mode

Each MetalLB speaker establishes a BGP session with the upstream router and advertises the service IP as a route. The router load-balances across all nodes using ECMP. This is production-grade but requires a BGP-capable router.

### Configuration

MetalLB needs two resources: an `IPAddressPool` defining which IPs it may assign, and an advertisement resource activating the mode.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - local-pool
```

When Envoy Gateway creates a `LoadBalancer` service for a `Gateway` resource, MetalLB assigns it an IP from the pool (e.g., `192.168.1.200`). That IP becomes the stable external address for the cluster's entry point — the one you put in DNS or `/etc/hosts`.

---

## cert-manager

cert-manager automates the full TLS certificate lifecycle in Kubernetes: issuance, storage, and renewal. It watches `Certificate` resources and writes the resulting cert and private key into a `kubernetes.io/tls` Secret that the Gateway can reference directly.

Without cert-manager you would obtain certificates manually, base64-encode them into Secrets by hand, and remember to renew them before expiry — Let's Encrypt certs last 90 days. cert-manager eliminates all of that.

### Issuers

An `Issuer` (namespace-scoped) or `ClusterIssuer` (cluster-wide) tells cert-manager which CA or ACME service to use.

**ACME / Let's Encrypt** — for publicly reachable domains. cert-manager completes an ACME challenge (HTTP-01 or DNS-01) to prove domain ownership, then Let's Encrypt issues a globally trusted certificate.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: public-gateway
                namespace: envoy-gateway
```

**Self-signed CA** — for private domains (homelab, internal services). cert-manager generates a self-signed root CA and issues certificates from it. You distribute the root CA to browsers or workstations that need to trust it.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

### Certificate resources

A `Certificate` resource requests a cert for one or more hostnames. cert-manager issues it and writes the result into a Secret:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: todo-tls
  namespace: envoy-gateway
spec:
  secretName: todo-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - todo.example.com
```

cert-manager renews the certificate automatically at roughly 2/3 of its lifetime (around day 60 for Let's Encrypt certs), so the secret is always current.

### Wiring TLS into the Gateway

Add an HTTPS listener to the Gateway that references the Secret:

```yaml
listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
        - name: todo-tls-secret
          namespace: envoy-gateway
    allowedRoutes:
      namespaces:
        from: All
```

The Envoy proxy terminates TLS on port 443 using the managed certificate. HTTPRoutes are unchanged — from their perspective traffic arrives as plain HTTP from the proxy.

### Complete HTTPS traffic flow

```
Client
  ↓ HTTPS (TLS handshake, cert issued by cert-manager)
Envoy Proxy :443 — TLS terminated here
  ↓ plain HTTP internally
Gateway API route matching
  ↓
Service → Pod
```

---

## Alternative Implementations

The Gateway API is implementation-agnostic. Other controllers that implement it include:

| Implementation        | Backing proxy    | Notes                                       |
|-----------------------|------------------|---------------------------------------------|
| **Envoy Gateway**     | Envoy Proxy      | CNCF reference implementation; used here   |
| **nginx Gateway Fabric** | nginx         | Official nginx Gateway API controller       |
| **Istio**             | Envoy (via Istio)| Full service mesh; Gateway API support built in |
| **Traefik**           | Traefik          | Popular in homelab setups                   |
| **Cilium Gateway API**| eBPF             | High-performance; requires Cilium CNI       |

All of them read the same `GatewayClass`, `Gateway`, and `HTTPRoute` resources. If you write HTTPRoutes against Envoy Gateway today, they work against nginx Gateway Fabric tomorrow without changes.

---

## Comparison

| Feature                  | NodePort        | Ingress              | Gateway API             |
|--------------------------|-----------------|----------------------|-------------------------|
| **Standard port (80)**   | No (30000–32767)| Yes                  | Yes                     |
| **URL-based routing**    | No              | Yes (limited)        | Yes (full)              |
| **Hostname routing**     | No              | Yes                  | Yes                     |
| **TLS termination**      | No              | Yes (via annotation) | Yes (first-class spec)  |
| **Header matching**      | No              | Limited              | Yes                     |
| **Role-based ownership** | No              | No                   | Yes                     |
| **Vendor annotations**   | N/A             | Required             | Not needed              |
| **Multi-namespace**      | Per-namespace   | Cluster-wide         | Cross-namespace routes  |
| **Stability**            | Stable          | Stable               | Stable (v1, K8s 1.28+) |

---

## Further Reading

- **[Kubernetes Gateway API documentation](https://gateway-api.sigs.k8s.io/)** — official spec and user guides, including the role model and route attachment rules
- **[Envoy Gateway documentation](https://gateway.envoyproxy.io/docs/)** — installation, architecture, and feature reference
- **[Envoy Proxy documentation](https://www.envoyproxy.io/docs/)** — deep dive into the proxy itself (xDS, filters, load balancing)
- **[Gateway API concepts: GatewayClass, Gateway, HTTPRoute](https://gateway-api.sigs.k8s.io/concepts/api-overview/)** — visual explanation of the three-tier model
- **[From Ingress to Gateway API](https://kubernetes.io/blog/2023/10/31/gateway-api-ga/)** — Kubernetes blog post on the GA of Gateway API v1
- **[MetalLB documentation](https://metallb.universe.tf/)** — Layer 2 and BGP configuration, address pools, and troubleshooting
- **[cert-manager documentation](https://cert-manager.io/docs/)** — issuers, Certificate resources, ACME solvers, and Gateway API integration
