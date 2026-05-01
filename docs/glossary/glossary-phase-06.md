# Glossary - Phase 06: Routing and Traffic Exposure

### Gateway API

The official Kubernetes standard for managing external access to services, replacing Ingress.
It uses a role-based three-tier model (GatewayClass → Gateway → HTTPRoute) with first-class spec fields instead of vendor-specific annotations, making routing rules portable across implementations.

---

### GatewayClass

A cluster-scoped resource that represents a type of gateway controller (for example, Envoy Gateway or nginx Gateway Fabric).
It is the bridge between the Gateway API spec and the actual proxy implementation that handles traffic.

---

### Gateway

A namespace-scoped resource that represents a running load balancer or proxy instance.
It defines which ports and protocols to listen on and which namespaces may attach routes to it.
When created, the controller (such as Envoy Gateway) provisions a dedicated proxy Deployment and a LoadBalancer Service for it.

---

### HTTPRoute

A namespace-scoped resource that defines HTTP routing rules for traffic entering through a Gateway.
It specifies hostnames, path matching, backend services, and optional request transformations, and it attaches to a Gateway via `parentRefs`.

---

### Ingress

The legacy Kubernetes resource for exposing HTTP services externally.
It relies on vendor-specific annotations and a per-implementation controller, making rules non-portable.
The Gateway API is its official successor.

---

### Envoy Gateway

A CNCF reference implementation of the Kubernetes Gateway API that uses Envoy Proxy as its data plane.
Its control plane watches Gateway API resources and translates them into Envoy xDS configuration, enabling dynamic proxy updates without restarts.

---

### Envoy Proxy

A high-performance, open-source Layer 7 proxy originally built at Lyft.
It serves as the data plane for Envoy Gateway (and other service meshes such as Istio), handling the actual HTTP/HTTPS traffic routing, TLS termination, and header manipulation.

---

### MetalLB

A load balancer implementation for bare-metal Kubernetes clusters.
On cloud providers, `LoadBalancer` Services receive an external IP automatically; MetalLB provides the same capability on clusters without a cloud controller by assigning IPs from a configured pool.

---

### IPAddressPool

A MetalLB custom resource that defines a range of IP addresses available for assignment to `LoadBalancer` Services.
When a Service of type `LoadBalancer` is created, MetalLB picks an IP from a matching pool.

---

### L2Advertisement

A MetalLB custom resource that activates Layer 2 mode and associates it with one or more IP address pools.
In Layer 2 mode, MetalLB elects one node to own each service IP and responds to ARP requests for it on the local network.

---

### cert-manager

A Kubernetes add-on that automates the full lifecycle of TLS certificates — issuance, renewal, and storage.
It watches `Certificate` resources, requests certificates from a configured issuer (such as Let's Encrypt or a self-signed CA), and stores the result as a Kubernetes `Secret` of type `kubernetes.io/tls`.

---

### ClusterIssuer

A cluster-scoped cert-manager resource that defines how certificates are issued across all namespaces.
Common issuers include ACME (Let's Encrypt) for public domains and self-signed CAs for private or homelab environments.

---

### Certificate (cert-manager)

A cert-manager resource that declares a desired TLS certificate — including the hostnames it should cover and which `ClusterIssuer` or `Issuer` should sign it.
cert-manager reconciles this resource by requesting the certificate and writing the resulting key pair into a Kubernetes `Secret`.

---

### TLS Termination

The process of decrypting inbound HTTPS traffic at the proxy layer and forwarding plain HTTP to backend services.
With the Gateway API, the Gateway handles TLS termination using a certificate stored in a Secret; backend services never need to handle HTTPS directly.

---

### Self-Signed CA Chain

A three-step cert-manager setup used in environments without a public CA.
First, a bootstrap `ClusterIssuer` signs its own root certificate; that certificate becomes a `ClusterIssuer` backed by a private CA `Secret`; finally, app `Certificate` resources request certificates from that CA.

---

### Helm Hook

An annotation-based mechanism that runs a Helm manifest at a specific point in the release lifecycle (for example, `post-install` or `pre-delete`).
Used in MetalLB to ensure that custom resources (such as `IPAddressPool`) are only applied after their CRDs have been registered in the cluster.

---

### Hostname-Based Routing

A routing strategy where incoming requests are directed to different backends based on the `Host` header of the HTTP request.
In the Gateway API, an `HTTPRoute` declares one or more `hostnames`; a matching Gateway forwards requests to the route whose hostname matches the client's `Host` header.

---

### allowedRoutes

A field on a `Gateway` listener that controls which namespaces may attach `HTTPRoute` resources to it.
Using `namespaces.from: Selector` with a label (for example, `expose-via-gateway: "true"`) restricts attachment to explicitly labelled namespaces, preventing unauthorized services from being exposed.
