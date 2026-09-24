# Phase 07 — Identity and Access Management with Authentik

This phase adds centralized authentication to the cluster. You will deploy authentik as the identity provider, protect the todo-app and Longhorn UI behind forward-auth via Envoy Gateway, and manage users and application access from a single dashboard.

**Starting point:** a working Phase 06 cluster with MetalLB, Envoy Gateway, cert-manager, Longhorn, and the todo-app — all reachable through the Gateway over HTTPS.

**What you build in this phase:**

| Artifact | Purpose |
|---|---|
| `apps/authentik/` | Helm wrapper that deploys authentik (server, worker, PostgreSQL) |
| Updated `apps/envoy-gateway/` | Adds `authentik.local` to the TLS certificate |
| Updated `apps/longhorn/` | Adds a `SecurityPolicy` and outpost callback route to protect the Longhorn UI |
| Updated `application/chart/` | Adds an outpost callback route template and `headersToExtAuth` to the `SecurityPolicy` |
| Updated todo-app values | Enables `frontend.auth.enabled: true` to activate forward-auth |

Compare your work with `solution/` when you are done.

---

## How it works

```
User → https://todo.local
     → Envoy Gateway matches the HTTPRoute
     → SecurityPolicy triggers ext-auth → authentik outpost
     → No valid session cookie?
         YES → 200, request proceeds to todo-app
         NO  → 302 redirect to https://authentik.local (login)
               → User authenticates
               → Redirect to https://todo.local/outpost.goauthentik.io/callback
               → Outpost sets session cookie, redirects to original URL
               → Repeat: ext-auth → cookie valid → 200
```

The key idea: **Envoy delegates authentication to authentik before allowing requests through**. Every protected service gets a `SecurityPolicy` that consults the authentik outpost. The outpost runs embedded inside the authentik server — no separate deployment needed.

Two important resources make cross-namespace auth work:

- **ReferenceGrant** — allows `SecurityPolicy` and `HTTPRoute` in the `todo` / `longhorn` namespaces to reference the `authentik-server` Service in the `authentik` namespace
- **Outpost callback HTTPRoute** — a second route on the same hostname (`/outpost.goauthentik.io/`) that sends the auth callback directly to authentik, bypassing the `SecurityPolicy` (otherwise the callback itself would trigger ext-auth, creating a redirect loop)

---

## Step 1 — Prerequisites

```bash
# Cluster with Phase 06 running
kubectl get pods -n envoy-gateway
kubectl get pods -n longhorn
kubectl get pods -n todo

# Gateway IP assigned
kubectl get svc -n envoy-gateway

# HTTPS working
curl -sk https://todo.local -o /dev/null -w "%{http_code}\n"
# Expected: 200
```

---

## Step 2 — Add `authentik.local` to the TLS certificate

Before deploying anything, extend the existing TLS certificate to cover the new hostname.

Update `apps/envoy-gateway/templates/certificate.yaml`:

```yaml
spec:
  dnsNames:
    - todo.local
    - longhorn.local
    - authentik.local        # ← add this
```

Redeploy:

```bash
helm upgrade --install cluster-envoy-gateway ./apps/envoy-gateway \
  -f ./apps/envoy-gateway/values/prod-values.yaml \
  -n envoy-gateway --wait

kubectl get certificate -n envoy-gateway
# Expected: gateway-tls   True
```

---

## Step 3 — Create and deploy the Authentik chart

### 3a — Create the wrapper chart

Create the following directory structure:

```
apps/authentik/
├── Chart.yaml
├── values/
│   └── prod-values.yaml
└── templates/
    ├── route.yaml
    └── reference-grant.yaml
```

**`apps/authentik/Chart.yaml`**

```yaml
apiVersion: v2
name: cluster-authentik
type: application
version: 1.0.0
dependencies:
  - name: authentik
    version: 2026.8.3
    repository: https://charts.goauthentik.io
```

Check the latest available version before using the one above:

```bash
helm repo add authentik https://charts.goauthentik.io
helm search repo authentik/authentik --versions | head -5
```

**`apps/authentik/values/prod-values.yaml`**

The authentik chart is a dependency named `authentik`, so all subchart values nest under the `authentik:` key. The chart itself has an `authentik:` config section, which creates a double nesting:

```yaml
authentik:                        # ← subchart key (dependency name)
  fullnameOverride: authentik     # ← ensures service name is "authentik-server"

  authentik:                      # ← authentik's own config section
    secret_key: "placeholder"     # overridden at install via --set
    log_level: info
    error_reporting:
      enabled: false
    bootstrap_password: "placeholder"
    bootstrap_email: ""
    postgresql:
      password: "placeholder"     # must match postgresql.auth.password below

  server:
    replicas: 1

  worker:
    replicas: 1

  postgresql:
    enabled: true
    auth:
      password: "placeholder"     # must match authentik.postgresql.password above
    primary:
      persistence:
        storageClass: longhorn
        size: 2Gi
```

> **Why `fullnameOverride: authentik`?** The authentik chart generates service names from the release name by default. With release name `cluster-authentik`, the server service would be `cluster-authentik-server`. Setting `fullnameOverride: authentik` forces the service name to `authentik-server`, which matches the default `frontend.auth.backend.serviceName` in the todo-app chart and keeps things readable.

> **Why two password fields?** `authentik.postgresql.password` tells the authentik server how to connect to PostgreSQL. `postgresql.auth.password` tells the Bitnami PostgreSQL subchart what password to set for the database user. Both must be identical — if they diverge, the server cannot authenticate and enters a crash loop with `fe_sendauth: no password supplied`.

**`apps/authentik/templates/route.yaml`**

An HTTPRoute for the authentik UI at `authentik.local`:

```yaml
{{- if .Values.gatewayRoute.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: authentik-ui
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: {{ .Values.gatewayRoute.gateway.name }}
      namespace: {{ .Values.gatewayRoute.gateway.namespace }}
  hostnames:
    - {{ .Values.gatewayRoute.hostname | quote }}
  rules:
    - backendRefs:
        - kind: Service
          name: authentik-server
          port: 80
      matches:
        - path:
            type: PathPrefix
            value: {{ .Values.gatewayRoute.pathPrefix }}
{{- end }}
```

**`apps/authentik/templates/reference-grant.yaml`**

A `ReferenceGrant` in the `authentik` namespace allows `SecurityPolicy` and `HTTPRoute` objects in other namespaces to reference the `authentik-server` Service. Without this, Envoy Gateway rejects the cross-namespace backend reference.

One `ReferenceGrant` per consuming namespace:

```yaml
{{- if .Values.referenceGrant.enabled }}
{{- range .Values.referenceGrant.allowedNamespaces }}
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: authentik-ext-auth-{{ . }}
spec:
  from:
    - group: gateway.envoyproxy.io
      kind: SecurityPolicy
      namespace: {{ . }}
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: {{ . }}
  to:
    - group: ""
      kind: Service
      name: authentik-server
{{- end }}
{{- end }}
```

Add the corresponding values for the route and grants:

```yaml
# Add to prod-values.yaml, below the authentik subchart block:
gatewayRoute:
  enabled: true
  hostname: "authentik.local"
  gateway:
    name: public-gateway
    namespace: envoy-gateway
  pathPrefix: /

referenceGrant:
  enabled: true
  allowedNamespaces:
    - todo
    - longhorn
```

### 3b — Deploy Authentik

Create the namespace with the gateway label so HTTPRoutes can attach:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: authentik
  labels:
    expose-via-gateway: "true"
EOF
```

Generate a secret key (once, never change after install):

```bash
openssl rand -base64 36
```

Install:

```bash
helm dependency update ./apps/authentik

helm upgrade --install cluster-authentik ./apps/authentik \
  -f ./apps/authentik/values/prod-values.yaml \
  --set-string "authentik.authentik.secret_key=<your-generated-key>" \
  --set-string "authentik.authentik.bootstrap_password=<your-admin-password>" \
  --set-string "authentik.authentik.postgresql.password=<your-pg-password>" \
  --set-string "authentik.postgresql.auth.password=<your-pg-password>" \
  -n authentik \
  --wait --timeout 8m
```

> **Why `--set-string` for credentials?** Values passed via `--set-string` are never written to files on disk and override the placeholder values in `prod-values.yaml`. The `.env` + `bootstrap.sh` approach in the solution automates this.

Verify:

```bash
kubectl get pods -n authentik
# Expected: authentik-server, authentik-worker, cluster-authentik-postgresql — all Running

kubectl get httproute -n authentik
# Expected: authentik-ui   ["authentik.local"]

kubectl get referencegrant -n authentik
# Expected: authentik-ext-auth-todo, authentik-ext-auth-longhorn
```

Add to `/etc/hosts` (same Gateway IP as phase 06):

```
<GATEWAY-IP>  todo.local longhorn.local authentik.local
```

Open `https://authentik.local` — the login page should load. Sign in with `akadmin` and the bootstrap password you set.

---

## Step 4 — Configure Authentik (UI)

Configure authentik **before** enabling auth on the apps. This way, when you flip `auth.enabled: true` in the next steps, the outpost already knows which applications to protect and the flow works immediately.

### 4a — Set the Authentik domain

Go to **System → Settings**. Set the **authentik domain** field to `authentik.local` and save.

Without this, the Embedded Outpost shows a warning and authentication redirects will not work because authentik does not know its own external URL.

### 4b — Create the todo-app Application

1. Go to **Applications → Applications → Create**
2. Fill in:
   - **Name:** `todo-app`
   - **Slug:** `todo-app`
3. In the same form (step 2), select **Create a new provider** and choose **Proxy Provider**:
   - **Name:** `todo-app-forward-auth`
   - **Authorization flow:** `default-provider-authorization-implicit-consent`
   - **Mode:** **Forward auth (single application)**
   - **External host:** `https://todo.local`
4. Finish the wizard

> **Implicit consent vs explicit consent:** With implicit consent, the user is redirected to the app immediately after login — no "Do you authorize this application?" screen. Use explicit consent when you want users to review the permissions an app requests before granting access.

### 4c — Create the Longhorn Application

Same process:

1. **Applications → Applications → Create**
2. **Name:** `longhorn`, **Slug:** `longhorn`
3. Create provider inline:
   - **Name:** `longhorn-forward-auth`
   - **Mode:** **Forward auth (single application)**
   - **External host:** `https://longhorn.local`
4. Finish

### 4d — Verify the Embedded Outpost

Go to **Applications → Outposts**. Click the **authentik Embedded Outpost**. Both applications (`todo-app` and `longhorn`) should appear in the outpost's application list. If they do not, edit the outpost and add them.

The Embedded Outpost runs inside the authentik server process — it serves the `/outpost.goauthentik.io/` paths that the `SecurityPolicy` and callback routes point to. No separate outpost deployment is needed.

---

## Step 5 — Prepare the forward-auth templates

With authentik configured and ready to authenticate, prepare the Kubernetes resources that connect Envoy to it. This step creates all the templates; the next step activates them by flipping values.

### 5a — Update the SecurityPolicy in the canonical chart

The canonical chart already has `templates/frontend/security-policy.yaml` that renders an Envoy `SecurityPolicy` when `frontend.auth.enabled: true`. It needs one addition: `headersToExtAuth`, which tells Envoy which request headers to forward to the ext-auth backend. Without at least `cookie`, the session cookie never reaches authentik and every request is treated as unauthenticated — causing a redirect loop.

Update `application/chart/templates/frontend/security-policy.yaml`:

```yaml
  extAuth:
    failOpen: false
    headersToExtAuth:                                      # ← add this block
      {{- toYaml .Values.frontend.auth.headersToExtAuth | nindent 6 }}
    http:
      backendRefs:
        ...
```

The chart's default values already define `frontend.auth.headersToExtAuth` with `cookie`, `authorization`, and forwarded-* headers.

### 5b — Add the outpost callback route to the canonical chart

Create `application/chart/templates/frontend/outpost-route.yaml`:

```yaml
{{- if and .Values.frontend.gatewayRoute.enabled .Values.frontend.auth.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "todo-app.fullname" . }}-outpost-callback
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: {{ .Values.frontend.gatewayRoute.gateway.name }}
      namespace: {{ .Values.frontend.gatewayRoute.gateway.namespace }}
  hostnames:
    - {{ .Values.frontend.gatewayRoute.hostname | quote }}
  rules:
    - backendRefs:
        - kind: Service
          name: {{ .Values.frontend.auth.backend.serviceName }}
          namespace: {{ .Values.frontend.auth.backend.namespace }}
          port: {{ .Values.frontend.auth.backend.port }}
      matches:
        - path:
            type: PathPrefix
            value: /outpost.goauthentik.io/
{{- end }}
```

> **Why a separate HTTPRoute?** The `SecurityPolicy` targets the main frontend HTTPRoute by name. If the outpost callback path (`/outpost.goauthentik.io/callback`) were part of the same route, Envoy would also run ext-auth on it — but the callback is the step that *establishes* the session. Running ext-auth on it creates a redirect loop. A second HTTPRoute with a longer path prefix (`/outpost.goauthentik.io/` vs `/`) takes precedence in Gateway API routing, and the `SecurityPolicy` does not apply to it.

### 5c — Add auth templates to the Longhorn wrapper chart

The Longhorn wrapper chart needs the same two resources. Create both files:

**`apps/longhorn/templates/security-policy.yaml`**

```yaml
{{- if .Values.auth.enabled }}
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: longhorn-forward-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: longhorn-ui
  extAuth:
    failOpen: false
    headersToExtAuth:
      {{- toYaml .Values.auth.headersToExtAuth | nindent 6 }}
    http:
      backendRefs:
        - group: ""
          kind: Service
          name: {{ .Values.auth.backend.serviceName }}
          namespace: {{ .Values.auth.backend.namespace }}
          port: {{ .Values.auth.backend.port }}
      path: {{ .Values.auth.path | quote }}
      headersToBackend:
        {{- toYaml .Values.auth.headersToBackend | nindent 8 }}
{{- end }}
```

**`apps/longhorn/templates/outpost-route.yaml`**

```yaml
{{- if .Values.auth.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: longhorn-outpost-callback
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: {{ .Values.gatewayRoute.gateway.name }}
      namespace: {{ .Values.gatewayRoute.gateway.namespace }}
  hostnames:
    - {{ .Values.gatewayRoute.hostname | quote }}
  rules:
    - backendRefs:
        - kind: Service
          name: {{ .Values.auth.backend.serviceName }}
          namespace: {{ .Values.auth.backend.namespace }}
          port: {{ .Values.auth.backend.port }}
      matches:
        - path:
            type: PathPrefix
            value: /outpost.goauthentik.io/
{{- end }}
```

---

## Step 6 — Enable auth and deploy

All templates are in place and authentik is configured. Now flip the switch.

### 6a — Enable auth for the todo-app

Update `apps/todo-app/values/prod-values.yaml`:

```yaml
frontend:
  auth:
    enabled: true      # ← change from false to true
```

Redeploy:

```bash
helm upgrade --install my-app <chart-path> \
  -f ./apps/todo-app/values/prod-values.yaml \
  -n todo --wait
```

### 6b — Enable auth for Longhorn

Update `apps/longhorn/values/prod-values.yaml` — add the `auth` block:

```yaml
auth:
  enabled: true
  path: /outpost.goauthentik.io/auth/envoy
  headersToExtAuth:
    - cookie
    - authorization
  backend:
    serviceName: authentik-server
    namespace: authentik
    port: 80
  headersToBackend:
    - x-authentik-username
    - x-authentik-groups
    - x-authentik-entitlements
    - x-authentik-email
    - x-authentik-name
    - x-authentik-uid
```

Redeploy:

```bash
helm upgrade --install cluster-longhorn ./apps/longhorn \
  -f ./apps/longhorn/values/prod-values.yaml \
  -n longhorn --wait
```

### 6c — Verify resources

```bash
kubectl get securitypolicy -A
# Expected: longhorn-forward-auth (longhorn), my-app-todo-app-frontend-auth (todo)
# Both should show status: Accepted

kubectl get httproute -A
# Expected: 5 routes — authentik-ui, longhorn-ui, longhorn-outpost-callback,
#           my-app-todo-app-frontend, my-app-todo-app-outpost-callback
```

---

## Step 7 — Test the authentication flow

Clear your browser cookies (or open an incognito window) and navigate to `https://todo.local`.

Expected flow:

1. Browser redirects to `https://authentik.local` with a login form
2. Log in as `akadmin` with your bootstrap password
3. Browser redirects back to `https://todo.local` — the todo-app loads
4. Open `https://longhorn.local` — since you already have a session, it loads without asking for credentials again (SSO)

```bash
# From the command line:
# Without cookie → redirect to authentik
curl -sk https://todo.local -o /dev/null -w "%{http_code}\n"
# Expected: 302
```

---

## Step 8 — Create users and manage access

### 8a — Create a user

1. Go to **Directory → Users → Create**
2. Fill in:
   - **Username:** `john`
   - **Name:** `John Doe`
   - **Email:** `john@example.com`
3. Save the user
4. Click the user → **Set password** → set a password

The user can now log in at `https://authentik.local`, but has access to all applications by default.

### 8b — Use groups for scalable access control

Instead of binding users one by one to applications, use groups:

1. **Directory → Groups → Create** — create a group (e.g., `platform-admins`)
2. Add users to the group (Directory → Groups → `platform-admins` → Users → Add)
3. Bind the group to an application:
   - **Applications → todo-app → Policy / Group / User Bindings → Bind existing policy/group/user**
   - Choose **Group** and select `platform-admins`

All members of `platform-admins` can now access `todo-app`. Add or remove users from the group to manage access without touching application bindings.

### 8c — Restrict Longhorn to admins only

To ensure only administrators can access Longhorn:

1. **Applications → longhorn → Policy / Group / User Bindings**
2. Bind the built-in `authentik Admins` group
3. Remove any open default bindings

Now only users in the `authentik Admins` group (like `akadmin`) can reach `https://longhorn.local`. Regular users like `john` will see an "Access denied" page.

---

## Step 9 — Verify

```bash
# All authentik pods running
kubectl get pods -n authentik
# Expected: authentik-server, authentik-worker, postgresql — all Running

# Services
kubectl get svc -n authentik
# Expected: authentik-server (ClusterIP, ports 80/443)

# All HTTPRoutes present
kubectl get httproute -A
# Expected: 5 routes across authentik, longhorn, and todo namespaces

# SecurityPolicies accepted
kubectl get securitypolicy -A
# Expected: longhorn-forward-auth (Accepted), my-app-todo-app-frontend-auth (Accepted)

# ReferenceGrants in place
kubectl get referencegrant -n authentik
# Expected: authentik-ext-auth-todo, authentik-ext-auth-longhorn

# TLS certificate includes authentik.local
kubectl get certificate -n envoy-gateway -o yaml | grep -A5 dnsNames
# Expected: todo.local, longhorn.local, authentik.local

# Authentik UI accessible
curl -sk https://authentik.local -o /dev/null -w "%{http_code}\n"
# Expected: 302 (redirect to login flow)

# Protected apps redirect to login when unauthenticated
curl -sk https://todo.local -o /dev/null -w "%{http_code}\n"
# Expected: 302
```

---

## Troubleshooting checklist

- **authentik server CrashLoopBackOff with `fe_sendauth: no password supplied`** — the PostgreSQL connection password is missing or mismatched. Ensure `authentik.authentik.postgresql.password` and `authentik.postgresql.auth.password` are identical. If the PostgreSQL PVC already has data with a different password, delete the PVC and reinstall: `helm uninstall cluster-authentik -n authentik && kubectl delete pvc -n authentik --all`
- **`ERR_TOO_MANY_REDIRECTS` on todo.local or longhorn.local** — the `SecurityPolicy` is missing `headersToExtAuth` with `cookie`. Without it, Envoy never sends the session cookie to the ext-auth backend, so every request is unauthenticated. Add `headersToExtAuth: [cookie, authorization]` under `extAuth` in the SecurityPolicy template
- **404 "Not Found" page from authentik when accessing todo.local** — the Proxy Provider is not assigned to the Embedded Outpost. Go to Applications → Outposts → authentik Embedded Outpost and verify both applications appear in the list
- **"authentik Domain is not configured" warning on the outpost** — go to System → Settings and set the authentik domain to `authentik.local`
- **SecurityPolicy status is not `Accepted`** — check that the `ReferenceGrant` in the `authentik` namespace exists and allows the correct source namespaces. Also verify the `authentik-server` service exists: `kubectl get svc -n authentik`
- **HTTPRoute shows `NotResolvedRefs`** — the backend service name does not match. Verify `fullnameOverride: authentik` is set in the authentik chart values, which produces the service name `authentik-server`
- **authentik UI loads but shows a blank page** — browser may be blocking self-signed resources. Import the homelab CA into your browser trust store (see Phase 06 Step 7)
- **Login works but app still shows 302** — clear cookies and try in an incognito window. Old cookies from a misconfigured attempt can persist and confuse the session

---

## Additional exercises

1. **OIDC login for the todo-app** — instead of forward-auth, create an OAuth2/OpenID Provider in authentik and modify the todo-app backend to authenticate directly via OIDC. The well-known endpoint is `https://authentik.local/application/o/<slug>/.well-known/openid-configuration`.
2. **Domain-level forward auth** — switch the Proxy Providers from "Forward auth (single application)" to "Forward auth (domain level)". This uses a single cookie domain for all applications, so the outpost callback only needs to run on the authentik hostname. Compare the trade-offs.
3. **Two-factor authentication** — enable TOTP in authentik (Flows → Stages → add an Authenticator Validation Stage to the default authentication flow). Log in as a regular user and confirm the TOTP prompt appears.
4. **Self-service enrollment** — create an enrollment flow so users can register without admin intervention. Test by opening an incognito window and clicking "Sign up" on the login page.
5. **Password recovery** — configure an email stage with a local SMTP server (like MailHog) and test the password recovery flow end-to-end.
6. **Application-level MFA** — create an authorization flow that requires MFA only for the `longhorn` application (admin tooling) but not for `todo-app`.

---

## Further reading

- [authentik documentation](https://goauthentik.io/docs/)
- [authentik Proxy Provider — Forward auth](https://goauthentik.io/docs/providers/proxy/forward_auth)
- [Envoy Gateway SecurityPolicy — ExtAuth](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/)
- [Gateway API ReferenceGrant](https://gateway-api.sigs.k8s.io/api-types/referencegrant/)
- [Kubernetes Gateway API — Route precedence](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)

---

## Success criteria

- `apps/authentik/` wrapper chart installed; server, worker, and PostgreSQL pods are Running
- `authentik-server` Service exists with `ClusterIP` on ports 80/443
- `authentik.local` is reachable via the Gateway over HTTPS and shows the login page
- TLS certificate includes `authentik.local` in `dnsNames`
- `ReferenceGrant` resources in the `authentik` namespace allow `todo` and `longhorn`
- `SecurityPolicy` for both todo-app and longhorn is `Accepted` and includes `headersToExtAuth` with `cookie`
- Outpost callback HTTPRoutes exist for both `todo.local` and `longhorn.local`
- Two Applications with Proxy Providers (forward auth, single application) are created in the authentik UI and assigned to the Embedded Outpost
- Unauthenticated access to `https://todo.local` or `https://longhorn.local` redirects to the authentik login
- After login, both apps load and SSO works across them (login once, access both)
- A non-admin user can be created, assigned to a group, and granted access to specific applications
