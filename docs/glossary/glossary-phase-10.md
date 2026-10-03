# Glossary - Phase 10: Observability and Monitoring

### Observability

The property of a system that lets you answer questions you did not anticipate, using only the telemetry it already emits.
Monitoring watches known signals for known failures ("disk above 90 %"); observability is what lets you find out *why* something unexpected happened.

---

### Telemetry Signals

The three kinds of data a system emits about itself: **metrics** (numbers over time), **logs** (timestamped events), and **traces** (the path of one request across services).
Metrics say *that* something is wrong and *where*; logs say *what* happened; traces say *where the time went*.

---

### Metric

A numeric measurement identified by a name and a set of labels, sampled over time (e.g., `http_requests_total{route="/api/v1/", status_code="200"}`).
It is cheap to store and aggregate, which makes it the basis for dashboards and alerting.

---

### Time Series

One metric name plus one unique combination of label values, with its list of (timestamp, value) samples.
Every new label value creates a new series that Prometheus must keep in memory, which is why label choice matters.

---

### Cardinality

The number of distinct time series (or log streams) a metric (or log source) produces: the product of the number of values of each label.
High-cardinality labels such as user IDs, note names, or full URL paths make series grow with your data until the backend runs out of memory; labels are for dimensions you aggregate by, never for identifiers.

---

### Counter

A metric type that only goes up, and resets to zero when the process restarts (e.g., `http_requests_total`).
Its raw value is rarely useful; `rate()` turns it into a per-second speed and handles resets automatically.

---

### Gauge

A metric type that can go up and down, representing a current value (e.g., memory in use, items in a queue, replicas available).
It is read as-is or summarised over a window with functions such as `avg_over_time` or `max_over_time`.

---

### Histogram

A metric type that counts observations into configurable buckets (`_bucket{le="0.1"}`), plus their `_sum` and `_count`.
Buckets from several Pods can be summed before computing a quantile with `histogram_quantile`, which is why histograms are preferred over client-side summaries for latency.

---

### Instrumentation

Adding code to an application so that it exposes its own telemetry, usually through a client library.
The todo-app backend is instrumented with `prom-client`, which serves request counters, latency histograms, and Node.js process metrics on `/metrics`.

---

### Scrape (Pull Model)

The act of Prometheus sending an HTTP `GET /metrics` to a target at a fixed interval and storing the returned samples.
Because Prometheus pulls, a target that stops answering is itself a signal: every scrape produces an `up` series that is `1` on success and `0` on failure.

---

### Exporter

A process that translates the internal state of a system that does not speak Prometheus (a node, a database, a proxy) into a `/metrics` endpoint.
node-exporter and kube-state-metrics are exporters; postgres_exporter would be one for the todo-app database.

---

### Prometheus

An open-source, CNCF-graduated monitoring system that scrapes metrics, stores them in a local time series database, evaluates alerting rules, and answers PromQL queries.
In this phase it scrapes every platform component and the todo-app backend, keeping 10 days of data on a Longhorn volume.

---

### TSDB and Retention

Prometheus's on-disk time series database, which stores samples in compressed two-hour blocks.
Retention deletes the oldest blocks after a time limit (`retention: 10d`) or a size limit (`retentionSize: 8GB`); keeping the size limit below the volume size prevents a full disk from stopping Prometheus.

---

### PromQL

The Prometheus query language, used in dashboards, Explore, and alerting rules.
Typical building blocks are `rate()` over counters, `sum by (label)` to aggregate, and `histogram_quantile()` for latency percentiles.

---

### Prometheus Operator

A Kubernetes operator that runs Prometheus and Alertmanager and generates their configuration from custom resources such as `ServiceMonitor`, `PodMonitor`, and `PrometheusRule`.
Adding a scrape target becomes shipping a Kubernetes object next to the workload, instead of editing one central `prometheus.yml`.

---

### ServiceMonitor

A Prometheus Operator custom resource that tells Prometheus to scrape the endpoints behind Services matching a label selector, on a named port and path.
Most charts can render one (`serviceMonitor.enabled: true`); the todo-app chart 0.2.0 does it for the backend, which is why its Service port is named `http`.

---

### PodMonitor

The Pod-level equivalent of a `ServiceMonitor`: it selects Pods directly by label and scrapes a named container port.
It is used for workloads without a suitable Service, such as the Flux controllers and the Envoy proxies created by Envoy Gateway.

---

### PrometheusRule

A Prometheus Operator custom resource holding recording rules (precomputed queries) and alerting rules.
kube-prometheus-stack installs around a hundred of them; a chart can ship its own to alert on application-specific conditions.

---

### Prometheus Operator CRDs

The `monitoring.coreos.com` CustomResourceDefinitions (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Prometheus`…), installed in this phase by a dedicated `prometheus-operator-crds` chart in the first layer.
Installing the CRDs before the operator lets every chart in every layer ship its own monitor without failing with `no matches for kind`.

---

### Alerting Rule

A PromQL expression plus a `for` duration: when the expression returns results the alert is **pending**, and if it keeps returning them for the whole duration it becomes **firing**.
The `for` clause keeps short blips (a single restart, one slow scrape) from notifying anybody.

---

### Alertmanager

The component that receives firing alerts from Prometheus and decides what to do with them: **grouping** related alerts, **inhibiting** less important ones, honouring **silences**, and **routing** them to receivers.
In this phase it has no receivers, so alerts are only visible in Grafana and in the Alertmanager UI.

---

### Receiver

An Alertmanager destination for notifications: email, Slack, Discord, PagerDuty, a webhook, and so on.
Configuring one needs a credential (a webhook URL or SMTP password), which in this platform means a SealedSecret.

---

### Watchdog (Dead Man's Switch)

An alert that always fires on purpose, proving that the pipeline from Prometheus to Alertmanager works.
In production it is sent to an external service that alerts *you* when the Watchdog stops arriving, which catches a broken monitoring stack.

---

### kube-prometheus-stack

A Helm chart that installs a complete monitoring system in one release: Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, default alerting rules, and dashboards.
On k3s, its control-plane monitors (scheduler, controller manager, kube-proxy, etcd) must be disabled, because k3s embeds those components without their metrics endpoints.

---

### node-exporter

An exporter, run as a DaemonSet, that exposes host-level metrics for each node: CPU, memory, filesystems, disks, and network.
It needs the host network, PID namespace, and root filesystem, which is why the `monitoring` namespace uses the `privileged` Pod Security level.

---

### kube-state-metrics

An exporter that turns the state of Kubernetes objects into metrics: desired vs available replicas, Pod phases, container restarts, waiting reasons.
Alerts such as `KubePodCrashLooping` and `KubeDeploymentReplicasMismatch` are built on its metrics.

---

### cAdvisor

The container resource monitor built into the kubelet, which exposes per-container CPU, memory, filesystem, and network usage.
Queries such as `container_memory_working_set_bytes{namespace="todo"}` read from it; no extra component needs to be installed.

---

### DaemonSet

A Kubernetes workload that runs one Pod on every node (or on a selected subset of nodes).
node-exporter and Alloy run as DaemonSets because each copy collects data that only exists on its own node.

---

### Pod Security Admission

The built-in Kubernetes admission controller that enforces the Pod Security Standards (`privileged`, `baseline`, `restricted`) per namespace, through `pod-security.kubernetes.io/*` labels.
A namespace labelled `enforce: restricted` rejects Pods that use host namespaces or hostPath volumes; `monitoring` is labelled `privileged` so node-exporter can run.

---

### Grafana

An open-source visualisation tool that queries many datasources (Prometheus, Loki, Alertmanager…) and shows the results as dashboards, ad-hoc queries (*Explore*), and alert views.
In this phase it is the single entry point to metrics, logs, and alerts, at `https://grafana.local` behind the authentik login.

---

### Datasource (Grafana)

A configured connection from Grafana to a backend, with a type (Prometheus, Loki…), a URL, and a `uid`.
Dashboards reference datasources by `uid`, so giving Loki a fixed `uid: loki` lets dashboards provisioned from Git find it on any cluster.

---

### Dashboards as Code

Keeping Grafana dashboards as JSON files in Git instead of only in Grafana's database.
Here a Kustomize `configMapGenerator` turns each file into a ConfigMap labelled `grafana_dashboard: "1"`, and a sidecar in the Grafana Pod loads it into the folder named by the `grafana_folder` annotation.

---

### `configMapGenerator`

A Kustomize feature that builds ConfigMaps from files or literals at build time, with optional labels and annotations.
It lets a dashboard live as a plain `.json` file that you can export from Grafana and commit unchanged, instead of JSON pasted inside YAML.

---

### Sidecar Container

A helper container that runs in the same Pod as the main application and extends it without changing its image.
The Grafana dashboard sidecar watches ConfigMaps in the cluster and writes matching dashboards into Grafana's provisioning directory.

---

### Break-Glass Account

A local account kept for emergencies, when the normal login path (here, authentik) is unavailable.
Grafana's `admin` user plays this role: its password is generated by the chart and stored in a Secret, and day-to-day access goes through SSO.

---

### Loki

A log aggregation system that indexes only a small set of labels per stream and stores the log lines compressed in chunks, instead of building a full-text index.
It is cheap to run and queried with LogQL; in this phase it runs in monolithic mode on a Longhorn volume with a 7-day retention.

---

### Log Stream (Loki)

The set of log lines sharing exactly the same labels (e.g., `{namespace="todo", pod="…", container="backend"}`).
Every new label combination creates a new stream, so Loki labels follow the same low-cardinality rule as Prometheus labels.

---

### LogQL

The Loki query language: a stream selector (`{namespace="todo"}`) followed by optional filters and parsers (`|= "error"`, `| json | status_code >= 500`).
Wrapping a query in functions such as `count_over_time` or `bytes_over_time` turns logs into metrics.

---

### Loki Deployment Modes

The three ways to run Loki: **monolithic** (every component in one process), **simple scalable** (separate read, write, and backend targets), and **microservices** (every component deployed separately).
The scalable modes require object storage such as S3 or MinIO; monolithic mode can use a local volume, which suits a homelab.

---

### Grafana Alloy

Grafana's telemetry collector, configured as a pipeline of components that discover targets, relabel them, and forward data to a backend.
In this phase each Alloy Pod follows the logs of the Pods on its node through the Kubernetes API and pushes them to Loki; it collects logs only, because Prometheus already scrapes the metrics.

---

### Promtail

Loki's original log collector, which tailed log files on each node.
It reached end of life in March 2026 and is replaced by Grafana Alloy.

---

### Structured Logging

Writing log lines in a machine-readable format, usually one JSON object per line, instead of free text.
LogQL can parse the fields at query time (`| json`), so logs can be filtered by `status_code` or `route` without regular expressions.

---

### USE Method

A checklist for resources (CPU, memory, disks, network): **U**tilization, **S**aturation, and **E**rrors.
node-exporter and the chart's *Node Exporter* and *Compute Resources* dashboards cover it.

---

### RED Method

A checklist for request-driven services: **R**ate (requests per second), **E**rrors (failed requests), and **D**uration (latency).
The todo-app dashboard is a RED view built from the backend's `http_requests_total` and `http_request_duration_seconds`.

---

### Four Golden Signals

Google SRE's four signals for user-facing systems: latency, traffic, errors, and saturation.
They overlap with USE and RED; all three start from what users experience rather than from every number a system can export.

---

### Service Level Objective (SLO)

A target for a service level indicator over a time window (e.g., "99 % of API requests succeed over 30 days").
The gap between the objective and 100 % is the error budget; burn-rate alerts fire when that budget is being spent too fast.

---

### Confidential Client

An OAuth 2.0 client that can keep a secret, because it runs on a server rather than in a browser or a mobile app.
Grafana is registered in authentik as a confidential client: its server exchanges the authorization code for tokens using the client secret.

---

### PKCE (Proof Key for Code Exchange)

An OAuth 2.0 extension where the client sends a hashed random value with the authorization request and the original value with the token request.
A stolen authorization code cannot be exchanged without that value; Grafana enables it with `use_pkce: true`.

---

### Role Mapping (Grafana)

Deriving a Grafana role (Admin, Editor, Viewer) from claims in the OIDC token, configured with `role_attribute_path`.
Here *authentik Admins* become Admin, *Grafana Editors* become Editor, and every other authentik user gets Viewer.

---

### authentik Blueprint

A YAML file describing authentik objects (providers, applications, groups, flows) that the authentik worker applies on startup and whenever the file changes.
It turns authentik configuration into code: the Grafana OIDC provider is declared in a blueprint mounted from a ConfigMap, with the client secret read from the environment through `!Env`.

---

### Ownership Labels (Flux)

The `kustomize.toolkit.fluxcd.io/name` and `kustomize.toolkit.fluxcd.io/namespace` labels that Flux sets on every object it applies.
Garbage collection only deletes objects that still carry the pruning Kustomization's labels, which is what makes it safe to move an object (such as a namespace) from one layer to another.
