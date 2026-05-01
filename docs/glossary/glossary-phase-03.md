# Glossary - Phase 03: Package Management

### Helm

A package manager for Kubernetes that simplifies installing, upgrading, and managing applications.
It combines templating and release management to avoid maintaining many static YAML files.

---

### Helm Chart

The package format used by Helm to describe a Kubernetes application.
A chart contains metadata, default values, and templates for Kubernetes resources.

---

### Chart.yaml

The metadata file inside a Helm chart.
It defines information such as chart name, version, description, and dependencies.

---

### values.yaml

The default configuration file for a Helm chart.
It provides variable values that templates consume to render environment-specific manifests.

---

### Template (Helm)

A Kubernetes manifest written with Go Template syntax and placeholders.
Templates are rendered into final YAML using chart values at install or upgrade time.

---

### Release

A deployed instance of a Helm chart in a Kubernetes cluster.
The same chart can produce multiple releases with different names and values.

---

### Revision

A version in the history of a Helm release.
Each successful upgrade creates a new revision that can be inspected or rolled back to.

---

### Rollback (Helm)

The operation that restores a release to a previous revision.
It is used to recover quickly when a new deployment introduces issues.

---

### helm install

A Helm command that creates a new release from a chart.
It can use default values or custom values files for a target environment.

---

### helm upgrade

A Helm command that updates an existing release with new templates or values.
It applies controlled configuration changes while preserving release history.
