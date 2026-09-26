# Glossary - Phase 07: Identity and Access Management

### Identity Provider (IdP)

A centralized service that manages user identities, credentials, and authentication decisions for multiple applications.
Instead of each application implementing its own login mechanism, a single IdP handles user creation, password policies, MFA enforcement, and session management — one place to grant or revoke access across all services.

---

### Forward Authentication

An architectural pattern where a reverse proxy delegates authentication to an external service before forwarding requests to the backend.
The proxy sends a subrequest to the auth service; if the user has a valid session, the request proceeds — otherwise the proxy redirects to a login page. The backend application never participates in the authentication challenge.

---

### OAuth 2.0

An authorization framework that allows applications to obtain limited access to user accounts on a third-party service.
It defines grant types (authorization code, client credentials, etc.) and token-based flows so that an application can act on behalf of a user without ever seeing their password.

---

### OpenID Connect (OIDC)

An identity layer built on top of OAuth 2.0 that adds authentication.
While OAuth 2.0 answers "what is this user allowed to do?", OIDC answers "who is this user?" by issuing an ID token (a signed JWT) containing identity claims such as username, email, and groups.

---

### Single Sign-On (SSO)

A mechanism that allows a user to authenticate once and gain access to multiple independent applications without logging in again.
An IdP issues a session token; every application protected by forward auth or OIDC trusts that token, so the user only enters credentials once per session.

---

### Authentik

An open-source Identity Provider written in Python (Django backend, React admin UI) that supports OAuth 2.0/OIDC, SAML, LDAP, RADIUS, SCIM, and forward auth via proxy providers.
Its flow-based architecture models every authentication process as a composable pipeline of stages gated by policies.

---

### Flow (Authentik)

An ordered sequence of stages that models a complete authentication process in Authentik — such as login, enrollment, password recovery, or logout.
Policies bound to each stage determine whether it executes, making the flow adaptive (for example, requiring MFA only for users outside a trusted network).

---

### Stage (Authentik)

An individual step within a flow — for example, showing a username prompt, verifying a password, validating a TOTP code, or sending an email.
Stages are reusable building blocks that can be arranged in different flows and gated by policies.

---

### Policy (Authentik)

A condition evaluated at runtime before a stage is presented to the user.
Policies enable conditional logic in flows: skip MFA for trusted networks, require a captcha after failed attempts, or restrict enrollment to users from a specific OAuth source.

---

### Outpost (Authentik)

A component that extends Authentik's authentication capabilities to the reverse proxy layer.
The proxy outpost implements the forward authentication protocol — it receives subrequests from the reverse proxy, validates session cookies, and returns either an approval (HTTP 200 with identity headers) or a redirect to the login page.

---

### Embedded Outpost

An outpost that runs inside the Authentik server container itself, requiring no separate deployment.
A lightweight internal router directs requests to `/outpost.goauthentik.io/*` to the embedded outpost instead of the core server.

---

### Proxy Provider (Authentik)

A provider type in Authentik that protects applications with no native SSO support via forward authentication.
It binds an application to an outpost and defines the external hostname and authentication mode (single application or domain-level).

---

### SecurityPolicy (Envoy Gateway)

An Envoy Gateway custom resource that attaches security rules — such as external authentication, CORS, or JWT validation — to a Gateway or HTTPRoute.
In this phase it is used to attach ext-auth rules that consult the Authentik outpost before allowing requests through to backend services.

---

### External Authentication (ext-auth)

An Envoy Gateway mechanism configured via `SecurityPolicy` that sends a subrequest to an external HTTP service before forwarding the client's request to the backend.
The external service (such as an Authentik outpost) returns HTTP 200 to approve or HTTP 401/403 to deny the request.

---

### headersToExtAuth

A field in the `SecurityPolicy` ext-auth configuration that specifies which request headers Envoy should forward to the external auth service.
Without at least `cookie`, the session cookie never reaches the auth backend and every request is treated as unauthenticated, causing a redirect loop.

---

### ReferenceGrant

A Gateway API resource that permits cross-namespace references between resources.
In this phase, a `ReferenceGrant` in the `authentik` namespace allows `SecurityPolicy` and `HTTPRoute` objects in other namespaces (such as `todo` or `longhorn`) to reference the `authentik-server` Service.

---

### Outpost Callback Route

A dedicated HTTPRoute that handles the OAuth callback path (`/outpost.goauthentik.io/`) without the `SecurityPolicy` applied.
This prevents a redirect loop — the callback is the step that establishes the session, so running ext-auth on it would trigger an infinite authentication cycle.

---

### MFA (Multi-Factor Authentication)

An authentication method that requires two or more verification factors — typically something the user knows (password) plus something they have (TOTP code, security key) or are (biometric).
A centralized IdP can enforce MFA for all users before any service is reachable.

---

### TOTP (Time-Based One-Time Password)

A second-factor authentication method that generates a short-lived numeric code based on a shared secret and the current time.
Apps like Google Authenticator or Authy produce these codes, which are valid for 30 seconds.

---

### WebAuthn / FIDO2

A passwordless authentication standard that uses public-key cryptography via hardware security keys or platform authenticators (fingerprint, face recognition).
Supported by Authentik as a second factor or as a primary passwordless authentication method.

---

### SAML 2.0 (Security Assertion Markup Language)

An XML-based SSO protocol widely used in enterprise environments for exchanging authentication and authorization data between an IdP and a service provider.
Authentik and Keycloak support it natively; Authelia does not.

---

### LDAP (Lightweight Directory Access Protocol)

A protocol for accessing and maintaining directory services — a hierarchical database of users, groups, and organizational units.
Authentik can expose an LDAP interface (provider) for legacy applications, while Authelia can only consume an existing LDAP directory as a user backend.

---

### SCIM (System for Cross-domain Identity Management)

A protocol for automating user and group provisioning and deprovisioning between an IdP and downstream services.
When a user is created or disabled in Authentik, SCIM can automatically sync that change to connected applications.

---

### Session Cookie

An HTTP cookie set by the IdP after successful authentication that identifies the user's active session.
The forward auth flow depends on this cookie — the reverse proxy forwards it to the auth service, which validates it and either approves or rejects the request.

---

### Credential Sprawl

The problem that arises when each application manages its own credentials, leading to separate usernames and passwords across services.
Users reuse or forget passwords, and there is no central place to enforce password policies or revoke access — a key motivation for deploying a centralized IdP.

---

### Authelia

A lightweight open-source authentication gateway written in Go (~30 MB memory), focused on forward authentication and OIDC.
It is not a full IdP — it reads users from a YAML file or LDAP directory and provides the auth portal and policy enforcement layer.

---

### Keycloak

An enterprise-grade open-source IdP (CNCF incubating project) written in Java (Quarkus), supporting OAuth 2.0/OIDC, SAML 2.0, LDAP/AD federation, and fine-grained authorization.
It requires significantly more resources (~1–2 GB memory) but offers the broadest protocol support and enterprise heritage.
