# Phase 07 - Identity and Access Management

Previous phases exposed services through the Gateway API with automatic TLS, but **any user who can reach the URL can access any service**. Longhorn's storage dashboard, for example, sits behind an HTTPRoute with no access control, anyone on the network can delete volumes, wipe backups, or reconfigure replication. The same applies to any internal tool, admin panel, or monitoring dashboard exposed through the Gateway.

This phase adds an **identity layer** in front of the cluster's services. Instead of building authentication into each application individually, a centralized Identity Provider (IdP) handles login, session management, and access decisions for every service behind the reverse proxy. The goal: one login, one place to manage users, and a single enforcement point that protects everything.

**Core concepts to master in this phase:**
- **Identity Provider (IdP) vs. authentication proxy**, the difference between managing identities and gating access
- **Forward authentication**, how a reverse proxy delegates auth decisions to an external service
- **OAuth 2.0 / OpenID Connect (OIDC)**, the protocol that makes SSO work across applications
- **Flows, stages, and policies**, how Authentik models authentication as a composable pipeline
- **Outposts**, how Authentik extends its authentication to the reverse proxy layer
- **Proxy provider**, how applications without native SSO support get protected anyway
- **MFA and passwordless authentication**, TOTP, WebAuthn, and FIDO2 as second factors

---

## Why an Identity Layer Matters

Without centralized authentication, every service either has no protection at all or implements its own login mechanism. This creates several problems:

**Unprotected admin interfaces.** Tools like Longhorn, Kubernetes Dashboard, or Grafana are designed to be used behind a corporate network or VPN. When exposed through a Gateway, even on a private LAN, they have no built-in authentication or only rudimentary protection. Longhorn explicitly states in its documentation that [authentication is not enabled by default](https://longhorn.io/docs/1.12.0/deploy/accessing-the-ui/), regardless of installation method. An attacker (or an accidental click) can adjust storage configurations, delete volumes, or destroy backups.

**Credential sprawl.** Each service with its own login means separate usernames and passwords. Users reuse credentials, forget which password belongs where, and there is no central place to enforce password policies or revoke access.

**No single sign-on.** Without SSO, users log in separately to every tool. With a centralized IdP, one authentication event grants access to all authorized services, and revoking a user's account disables access everywhere.

**No MFA enforcement.** Individual applications rarely enforce multi-factor authentication. A centralized IdP can require MFA for all users before any service is reachable.

---

## The Forward Authentication Pattern

The key architectural pattern in this phase is **forward authentication** (also called external authentication or auth-request). Instead of each application verifying credentials, the reverse proxy asks an external authentication service before forwarding the request.

The client (browser) sends a request to the reverse proxy (Envoy, nginx, or Traefik). The proxy makes an auth subrequest to the authentication service (Authentik or Authelia) asking whether the user is authenticated. If the auth service responds with 200 OK and X-Forwarded-User headers, the proxy forwards the request to Longhorn. If it responds with 401 Unauthorized, the proxy redirects the user to the login page.

The application itself never participates in the authentication challenge. It receives only authenticated requests, along with identity headers (`X-authentik-username`, `X-authentik-groups`, etc.) that identify who the user is. This means **any application can be protected, even those with no SSO support at all**.

### How it works step by step

1. The user requests `https://longhorn.local/`.
2. The reverse proxy intercepts the request and sends a subrequest to the authentication service.
3. The authentication service checks the session cookie attached to the request.
4. **If valid**: returns HTTP 200 with identity headers. The proxy forwards the original request to Longhorn, passing the identity headers along.
5. **If invalid or missing**: returns HTTP 401. The proxy redirects the user to the IdP's login page.
6. After successful login (username + password + optional MFA), the IdP sets a session cookie and redirects back to the original URL.
7. The proxy repeats the subrequest, this time the cookie is valid, so the request goes through.

---

## Authentik - The Identity Provider

[Authentik](https://goauthentik.io/) is an open-source Identity Provider written in Python (Django backend) with a modern React-based admin UI. Launched in 2020, it has grown to become one of the most popular self-hosted IdP solutions, with nearly 20,000 GitHub stars. Its core is licensed under MIT.

### Architecture

Authentik runs three components:

The **server container** runs two processes side by side: the core server (API, flows, SSO, admin UI) and an embedded outpost (proxy provider, forward auth), with a lightweight internal router splitting traffic between them. Below it sits the **worker container**, which handles asynchronous tasks such as email delivery, event notifications, and scheduled cleanups. Both containers depend on **PostgreSQL** (configuration, user data, audit logs) and **Redis** (sessions, caching, and the Celery task queue that connects the server to the worker).

- **Server**: handles API requests, flow execution, SSO protocol endpoints, and the admin UI. A lightweight internal router splits traffic between the core server and the embedded outpost.
- **Worker**: processes asynchronous tasks, sending emails, firing event notifications, scheduled cleanups. These tasks are visible in the admin interface.
- **PostgreSQL**: stores all configuration, user data, and audit logs.
- **Redis**: handles sessions, caching, and the Celery task queue between server and worker.

On Kubernetes, both the server and worker are deployed via the [official Helm chart](https://artifacthub.io/packages/helm/goauthentik/authentik), with PostgreSQL and Redis as dependencies (either bundled or external).

### Protocol support

Authentik is a **full multi-protocol identity provider**. It natively supports:

| Protocol | Use case |
|---|---|
| **OAuth 2.0 / OIDC** | SSO for modern web applications (OpenID Certified™) |
| **SAML 2.0** | SSO for enterprise applications |
| **LDAP** | Legacy applications and directory lookups |
| **RADIUS** | Network device authentication (switches, VPN) |
| **SCIM** | Automated user provisioning to downstream services |
| **Proxy provider** | Forward auth for applications with no SSO support |

This breadth is what distinguishes Authentik from lighter alternatives: it can act as both the identity source (where users live) and the SSO bridge (how applications verify those users).

### The flow system

The heart of Authentik is its **flow-based architecture**. Every authentication process, login, enrollment, recovery, logout, authorization, is modeled as a **flow**: an ordered sequence of **stages** gated by **policies**.

The "default-authentication-flow" proceeds through four stages in order. Stage 1 is identification, where the user enters a username or email; a "block-banned-IPs" policy can skip this stage if the IP is banned. Stage 2 is password verification. Stage 3 is MFA (TOTP or WebAuthn), gated by a "require-mfa-external-network" policy that skips this stage when the user is on a trusted network. Stage 4 is login, which creates the session.

- **Flows** define the overall process (authentication, enrollment, recovery).
- **Stages** are the individual steps: show a form, verify a password, check a TOTP code, send an email, redirect.
- **Policies** are conditions evaluated dynamically at runtime. A policy bound to a stage determines whether that stage executes. This allows conditional logic: require MFA only for users outside the corporate network, show a captcha only after failed attempts, or skip enrollment for users from a specific OAuth source.

Policies are evaluated right before the stage is presented to the user, making the flow adaptive rather than rigid. Authentik ships with sensible default flows, but the visual flow editor in the admin UI allows full customization.

### Outposts

An **outpost** is how Authentik extends its authentication capabilities outside of the core server. The most important outpost type for this phase is the **proxy outpost**, which implements forward authentication.

Authentik offers two deployment strategies for outposts:

**Embedded outpost**: runs inside the server container itself. The lightweight router directs requests to `/outpost.goauthentik.io/*` to the embedded outpost instead of the core server. This is the simplest approach, no extra deployment needed.

**Standalone outpost**: a separate pod (or container) that communicates with the Authentik core via WebSockets. Better for multi-application setups where you want the outpost closer to the applications it protects, or when you need to scale the auth layer independently.

Both outpost types implement the same forward auth protocol. The choice depends on deployment complexity and scale.

### How the proxy provider protects an application

When using the proxy provider with forward auth on Kubernetes:

1. You create an **Application** in Authentik (e.g., "Longhorn") and a **Proxy Provider** bound to it.
2. You assign the provider to an outpost.
3. On the ingress/route side, you configure forward auth annotations that point to the outpost's auth endpoint.
4. Every request to `longhorn.local` triggers the auth check: the reverse proxy asks the outpost, the outpost checks the session, and either approves or redirects.

The `external_host` field on the proxy provider must match the protected application's hostname, this ensures OAuth2 callback URLs and session cookies bind correctly.

### What you can configure

Authentik exposes a large surface of configurable behavior. The most relevant areas for this phase:

- **Authentication flows**: which stages appear during login, in what order, and under which conditions.
- **MFA enforcement**: require TOTP, WebAuthn/Passkeys, or hardware security keys for all users or specific groups.
- **User enrollment**: self-service signup, email verification, admin approval, or invitation-only.
- **Password policies**: minimum length, complexity rules, and checks against compromised password lists.
- **Group and role mappings**: assign users to groups, map groups to applications, and control who can access what.
- **Session duration and binding**: how long sessions last, whether they are bound to an IP or network range.
- **Branding and customization**: custom login pages, logos, and themes per application or tenant.
- **Social login sources**: authenticate via GitHub, Google, Microsoft Entra ID, or any external OAuth/SAML provider.
- **SCIM provisioning**: automatically sync users and groups to downstream services.
- **Audit logging**: every authentication event, policy decision, and admin action is logged with field-level detail.

---

## Alternatives to Authentik

### Authelia

[Authelia](https://www.authelia.com/) is an open-source authentication and authorization server written in Go with a React frontend, licensed under Apache 2.0. Unlike Authentik, **Authelia is not a full identity provider**, it is a **forward authentication service** that sits behind a reverse proxy and gates access to applications.

The key distinction: Authelia does not manage user identities centrally. It reads users from an external backend (a YAML file for small setups, or an LDAP directory for larger ones) and provides the authentication portal and policy enforcement layer.

**Strengths:**
- **Extremely lightweight.** The container image is under 20 MB compressed. Runtime memory usage is typically under 30 MB. CPU consumption is negligible at idle. This makes it ideal for resource-constrained environments like a Raspberry Pi or a small homelab.
- **Simple configuration.** Everything is defined in YAML files, no database required (for the local user backend). Configuration is declarative, version-controllable, and easy to reason about.
- **Fast.** Written in Go, authorization decisions complete in milliseconds. The portal loads in approximately 100 ms.
- **OpenID Certified™.** Authelia is a certified OpenID Connect 1.0 provider, so applications that support OIDC can use it for SSO.
- **Good proxy integration.** Works out of the box with Traefik (via `ForwardAuth` middleware), nginx (via `auth_request`), Caddy (via `forward_auth`), HAProxy, and Envoy.

**Limitations:**
- No SAML support, only OIDC for SSO.
- No LDAP *provider*, it can consume LDAP as a user backend, but cannot expose an LDAP interface to other applications.
- No visual admin UI, all management is through config files and CLI.
- No built-in user enrollment or self-service flows.
- No SCIM provisioning, RADIUS, or protocol bridging.

**When to choose Authelia:** if you want minimal resource usage, have few users, manage them in a YAML file or existing LDAP, and only need forward auth + OIDC. It excels in homelab setups where simplicity matters more than protocol breadth.

### Keycloak

[Keycloak](https://www.keycloak.org/) is the enterprise-grade open-source IdP, originally created by Red Hat in 2014 and now a **CNCF incubating project**. It is the most feature-complete option, supporting OAuth 2.0/OIDC, SAML 2.0, LDAP/AD federation, Kerberos, and fine-grained authorization.

**Strengths:**
- Mature and battle-tested in enterprise environments.
- Full SAML 2.0 support with complex attribute mappings.
- Active Directory / LDAP federation with real-time sync.
- Fine-grained authorization services (UMA 2.0).
- Kubernetes Operator for deployment and lifecycle management.
- Passkey and FIDO2 support in recent versions (26.x).

**Limitations:**
- **Heavy resource footprint.** Keycloak runs on Quarkus (Java) and requires significantly more memory (1–2 GB minimum) than either Authentik or Authelia.
- **Steep learning curve.** Concepts like realms, clients, mappers, and protocol flows require significant study.
- **Complex configuration model.** The admin console is powerful but dense, finding the right setting can be non-trivial.

**When to choose Keycloak:** if you need SAML for enterprise applications, Active Directory federation, or are already in a Red Hat ecosystem. Its CNCF backing and enterprise heritage make it the safe choice for large organizations.

### Comparison at a glance

| | **Authentik** | **Authelia** | **Keycloak** |
|---|---|---|---|
| **Type** | Full IdP | Auth gateway | Full IdP |
| **Language** | Python (Django) | Go | Java (Quarkus) |
| **OAuth2 / OIDC** | Yes (certified) | Yes (certified) | Yes |
| **SAML** | Yes | No | Yes |
| **LDAP provider** | Yes | No (consumer only) | Yes |
| **RADIUS** | Yes | No | No |
| **SCIM** | Yes | No | Partial |
| **Forward auth** | Yes (outpost) | Yes (core feature) | Via external proxy |
| **Admin UI** | Visual flow editor | YAML config | Full web console |
| **Memory footprint** | ~800 MB+ (with PostgreSQL/Redis) | ~30 MB | ~1–2 GB |
| **License** | MIT (core) | Apache 2.0 | Apache 2.0 |
| **CNCF** | No | No | Incubating |
| **Best for** | Homelab to mid-size | Minimal homelab | Enterprise |

---

## Practical Example: Protecting Longhorn

To illustrate why this matters, consider the Longhorn storage UI deployed in Phase 05. Without an identity layer:

```
Browser → https://longhorn.local/ → Gateway → Longhorn UI (no auth)
```

Anyone who can resolve `longhorn.local` has full admin access: delete volumes, destroy backups, reconfigure replication targets. Longhorn itself has [no built-in authentication mechanism](https://github.com/longhorn/longhorn/issues/1983).

With Authentik in the path:

The browser requests `https://longhorn.local/`, which hits the Gateway (Envoy). Envoy performs a forward auth check against the Authentik outpost. If the session is valid and the user belongs to the "admins" group, the outpost returns 200 and the request reaches the Longhorn UI. If there is no session, the outpost returns 401, the proxy redirects to the Authentik login page, the user enters username, password, and MFA, a session cookie is set, the browser is redirected back to `longhorn.local`, and Longhorn is now served authenticated.

The same pattern applies to any service: Grafana, Prometheus, ArgoCD, a container registry, or any internal tool. One IdP, one login, one place to manage access.

---

## Further Reading

- **[Authentik documentation](https://docs.goauthentik.io/)**, official docs covering installation, flows, outposts, providers, and Kubernetes deployment
- **[Authentik features overview](https://goauthentik.io/features/)**, full list of protocols, authentication methods, and enterprise features
- **[Flows, stages, and policies, Authentik blog](https://goauthentik.io/blog/2024-08-27-flows-stages-and-policies/)**, deep dive into the flow system from the Authentik team
- **[Authelia documentation](https://www.authelia.com/)**, official docs for configuration, proxy integration, and OIDC setup
- **[OpenID Connect with Authelia on Kubernetes, Stonegarden](https://blog.stonegarden.dev/articles/2025/06/authelia-oidc/)**, practical guide for deploying Authelia with OIDC on Kubernetes
- **[Authentik Proxy Outpost on Kubernetes: The Parts Nobody Documents, djieno.com](https://djieno.com/blog/authentik-proxy-outpost/)**, detailed walkthrough of forward auth with Authentik on Kubernetes, including the common pitfalls
- **[Authentik with Kubernetes: Forward Authentication using Ingress Nginx, Suraj Remanan](https://surajremanan.com/posts/authentik-with-kubernetes-forward-auth/)**, step-by-step setup of forward auth with nginx ingress
- **[SSO With Authentik, Xebia](https://xebia.com/blog/sso-with-authentik/)**, SSO setup and configuration guide for a local Kubernetes cluster
- **[What I learned wiring SSO across my homelab, Developer 2.0](https://developer20.com/homelab-sso-with-authentik/)**, real-world experience integrating Authentik across a homelab stack
- **[Authentik vs Authelia vs Keycloak, Elest.io](https://blog.elest.io/authentik-vs-authelia-vs-keycloak-choosing-the-right-self-hosted-identity-provider-in-2026/)**, detailed comparison of the three main self-hosted IdP options
- **[Authelia vs Authentik, Cerbos](https://www.cerbos.dev/blog/authelia-vs-authentik-2026-idp)**, focused comparison with architectural trade-offs
- **[Protect your application on Kubernetes with Authelia, Medium](https://medium.com/@findpritish/protect-your-application-on-kubernetes-with-authelia-4761c35d8ef4)**, practical Authelia deployment on Kubernetes
- **[Keycloak joins CNCF as an incubating project](https://www.cncf.io/blog/2023/04/11/keycloak-joins-cncf-as-an-incubating-project/)**, context on Keycloak's place in the cloud-native ecosystem
- **[Longhorn: Accessing the UI](https://longhorn.io/docs/1.12.0/deploy/accessing-the-ui/)**, Longhorn's own documentation on auth options (or lack thereof)
