# Phase 10: Observability and Monitoring

At the end of Phase 09 the cluster is a function of the repository: every component is declared in Git and Flux keeps reality in line with it. `flux get kustomizations` says *Ready*, and that is all it can say. Ready means "applied and healthy according to Kubernetes". It does not tell you that the backend answers one request in ten with a 500, that Longhorn is about to run out of space, that a certificate expires in three days, or what the backend logged right before it crashed.

This phase adds the missing feedback loop. Every component of the platform exposes its metrics, every container's logs are collected, and both end up in one Grafana instance behind the same authentik login as the rest of the homelab. The application itself is instrumented, so the questions you can answer move from "is the Pod running?" to "is the service doing its job?".

Nothing about the way you work changes: the observability stack is a set of `HelmRelease`s and manifests in the existing layers, reconciled by Flux like everything else.

**Core concepts to master in this phase:**
- **Monitoring vs observability**, and the three signals: metrics, logs and traces
- **Prometheus**: the pull model, the time series data model, metric types and PromQL
- **The Prometheus Operator**: `ServiceMonitor`, `PodMonitor` and `PrometheusRule` as Kubernetes objects
- **Cardinality**, the one mistake that can take down a metrics or logs backend
- **Loki and Alloy**: indexing labels instead of content, and collecting logs per node
- **Alerting**: rules, `for` durations and Alertmanager
- **Grafana as code**: datasources and dashboards provisioned from Git, SSO with OIDC
- **Instrumenting an application**: RED metrics and structured logs from the todo-app backend

---

## From "Running" to "Working"

**Monitoring** is watching known signals for known failure modes: CPU above 90 %, a disk filling up, a target that stopped answering. **Observability** is the property of a system that lets you answer questions you did not anticipate, from the data it already emits. You need monitoring to be woken up; you need observability to find out why.

Both rely on the same three kinds of telemetry:

| Signal | What it is | Good at | In this phase |
|---|---|---|---|
| **Metrics** | Numbers sampled over time, identified by a name and labels | Trends, rates, alerting, cheap long-term storage | Prometheus |
| **Logs** | Timestamped text (or JSON) events | The details of one event: an error message, a request | Loki, collected by Alloy |
| **Traces** | The path of one request across services, as a tree of timed spans | Latency in distributed systems | Not covered (additional exercise) |

Metrics tell you *that* something is wrong and *where* (which service, which route); logs tell you *what* happened. The todo-app dashboard built in this phase puts both on the same page for that reason.

---

## The Observability Pipeline

Every observability system, from a homelab to a SaaS vendor, has the same four stages:

| Stage | Question | Metrics | Logs |
|---|---|---|---|
| **Collect** | Who produces and gathers the data? | Each component exposes `/metrics`; Prometheus scrapes it | Containers write to stdout; Alloy follows the streams |
| **Store** | Where does it live and for how long? | Prometheus TSDB on a 10 Gi Longhorn volume, 10 days | Loki on a 5 Gi Longhorn volume, 7 days |
| **Query** | How do you ask questions? | PromQL | LogQL |
| **Visualize / alert** | How do humans find out? | Grafana dashboards, Prometheus rules → Alertmanager | Grafana Explore and dashboards |

Because the stages are separate, you can replace the stack one piece at a time: Alloy could ship to a hosted Loki, Prometheus could remote-write to Mimir or Thanos, and Grafana could read from both without knowing.

---

## Prometheus

### The pull model

Prometheus **pulls**: every scrape interval (30 s by default here) it sends an HTTP `GET /metrics` to each target and stores what comes back. Applications do not know where Prometheus is; they only publish their current values.

This has a useful side effect: a target that does not answer is itself a data point. Every scrape produces a synthetic `up` series (1 if the scrape succeeded, 0 if not), and "target down" is the most basic alert of all. In a push model, silence is ambiguous: the service could be idle or dead.

### The data model

A **time series** is a metric name plus a unique set of labels, with a list of (timestamp, value) samples:

```
http_requests_total{namespace="todo", method="GET", route="/api/v1/", status_code="200"}  1543
```

Labels make the data queryable ("sum by route", "only 5xx"). They are also the main cost: every unique combination of label values is a separate series that Prometheus keeps in memory.

### Metric types

| Type | Behaviour | Example | Typical query |
|---|---|---|---|
| **Counter** | Only goes up (resets to 0 on restart) | `http_requests_total` | `rate(...[5m])`: per-second increase |
| **Gauge** | Goes up and down | `container_memory_working_set_bytes` | The value itself, `avg_over_time` |
| **Histogram** | Counts observations into buckets (`_bucket{le="0.1"}`, `_sum`, `_count`) | `http_request_duration_seconds` | `histogram_quantile(0.95, ...)` |
| **Summary** | Quantiles computed in the client | Rare in new code | Cannot be aggregated across Pods |

The raw value of a counter is almost never interesting; its rate is. Histograms are preferred over summaries because buckets from several Pods can be summed before the quantile is computed.

### PromQL in four queries

These are the queries behind the todo-app dashboard:

```promql
# Requests per second, over the last 5 minutes
sum(rate(http_requests_total{namespace="todo"}[5m]))

# Fraction of requests that failed with a 5xx
sum(rate(http_requests_total{namespace="todo", status_code=~"5.."}[5m]))
  / sum(rate(http_requests_total{namespace="todo"}[5m]))

# 95th percentile latency per route
histogram_quantile(0.95,
  sum by (le, route) (rate(http_request_duration_seconds_bucket{namespace="todo"}[5m])))

# Is the backend being scraped at all?
up{namespace="todo"}
```

`rate()` turns a counter into a per-second speed, `sum by (...)` aggregates away the labels you do not care about (Pod, instance), and `histogram_quantile` turns buckets into a latency.

### Cardinality

**Cardinality** is the number of distinct series a metric produces: the product of the number of values each label can take. 4 methods × 5 routes × 6 status codes = 120 series, which is nothing. Add a label with the note name, the user ID or the full URL path and the count grows with your data until Prometheus runs out of memory.

The todo-app backend avoids this on purpose: the `route` label is the matched Express pattern (`/api/v1/:name`), never the real path (`/api/v1/shopping-list`). The same rule applies to log labels in Loki, below. **Labels are for dimensions you aggregate by, never for identifiers.**

---

## The Prometheus Operator

Configuring Prometheus by hand means one big `prometheus.yml` that lists every target. On Kubernetes, targets come and go and each team owns its own services, so the **Prometheus Operator** turns scrape configuration into Kubernetes objects:

| Custom resource | Describes | Created by |
|---|---|---|
| `Prometheus`, `Alertmanager` | The servers themselves (replicas, storage, retention) | kube-prometheus-stack |
| `ServiceMonitor` | "Scrape the endpoints behind Services matching these labels, on this port and path" | Each chart (cert-manager, Longhorn, authentik, Harbor, Loki, Alloy, the todo-app) |
| `PodMonitor` | The same, selecting Pods directly (for workloads without a suitable Service) | `infrastructure/configs/` (Flux controllers, Envoy proxies) |
| `PrometheusRule` | Recording and alerting rules | kube-prometheus-stack (default rules) |

The operator watches these objects and regenerates the Prometheus configuration whenever one appears, changes or disappears. To add a target, you ship a `ServiceMonitor` next to the Deployment, and whoever owns the Deployment owns the monitor.

### Selectors: who gets scraped

A `Prometheus` object selects the monitors it loads. By default, kube-prometheus-stack only picks up monitors labelled `release: kube-prometheus-stack`, which would force every chart to know the name of this release. This phase sets the `*SelectorNilUsesHelmValues: false` values, so Prometheus loads every `ServiceMonitor`, `PodMonitor` and `PrometheusRule` in every namespace. In a multi-tenant cluster you would do the opposite and select by label or namespace.

### Why the CRDs come first

A chart can only render a `ServiceMonitor` if the `monitoring.coreos.com` CRDs exist; otherwise the install fails with *no matches for kind "ServiceMonitor"*. kube-prometheus-stack ships those CRDs, but it is installed in the monitoring layer, and cert-manager and Longhorn (layer 1) want to ship monitors too.

The solution separates the CRDs from the operator. A `prometheus-operator-crds` `HelmRelease` in `infrastructure/controllers/` installs only the CRDs, in the very first layer, and kube-prometheus-stack is told not to install them again (`crds.enabled: false`). From then on, any chart in any layer can ship its own monitor. Both charts are pinned to the same Prometheus Operator version, which is the `appVersion` of each.

CRDs outlive the release that installs them. The chart renders them as ordinary templates, so removing the `HelmRelease` would make Helm delete them, and Kubernetes would cascade-delete every `ServiceMonitor`, `PrometheusRule` and the `Prometheus` object itself. The `helm.sh/resource-policy: keep` annotation (set through the chart's `crds.annotations`) tells Helm to leave them in place, the same protection cert-manager gets from `crds.keep: true`.

Inside layer 1, cert-manager and Longhorn are installed by the same Flux `Kustomization` as the CRDs, so the Kustomization-level `dependsOn` from Phase 09 cannot order them. `HelmRelease` objects have their own `spec.dependsOn`, which waits for another `HelmRelease` (here `kube-system/prometheus-operator-crds`) to be Ready:

| Level | Field | Orders |
|---|---|---|
| Flux `Kustomization` | `spec.dependsOn` | Whole layers (infra-controllers → infra-configs → …) |
| `HelmRelease` | `spec.dependsOn` | Releases inside one layer (CRDs → cert-manager, Loki → Alloy) |

Flux and Envoy Gateway are the exception. Flux is installed by the Flux Operator before any CRD exists, and the Envoy proxies are created by Envoy Gateway at runtime, so neither can ship a monitor in its own Helm values. Their monitors are plain manifests in `infrastructure/configs/` (`flux/monitors.yaml`, `gateway/pod-monitor.yaml`), next to the rest of the configuration of those components. The CRDs exist by then because `infra-configs` depends on `infra-controllers`.

**Two ways to see the state of Flux objects.** The Flux documentation and the [flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example) configure kube-state-metrics with a *custom resource state* config that turns every Flux object into a `gotk_resource_info` series. The Flux Operator, which installs Flux here, already exports the equivalent `flux_resource_info{kind, name, ready, suspended…}` on its metrics port, so this phase only scrapes the operator. With `flux bootstrap` instead of the operator, the kube-state-metrics approach is the one to use.

---

## kube-prometheus-stack

One chart, one `HelmRelease`, and a complete monitoring system:

| Component | Job |
|---|---|
| **Prometheus Operator** | Turns the CRDs above into running servers and configuration |
| **Prometheus** | Scrapes, stores and evaluates rules |
| **Alertmanager** | Receives firing alerts, groups and routes them |
| **Grafana** | Dashboards and Explore, with Prometheus and Alertmanager already configured as datasources |
| **node-exporter** | DaemonSet with host metrics: CPU, memory, disks, network of each node |
| **kube-state-metrics** | The state of Kubernetes objects as metrics: replicas desired vs available, Pod phases, restarts |
| **Default rules and dashboards** | Around a hundred alerting rules and two dozen dashboards maintained by the kube-prometheus project |

Grafana is not installed separately: the chart's Grafana subchart is already wired to the other components, so a second Grafana would only add work.

### k3s specifics

k3s runs the scheduler, the controller manager, kube-proxy and the datastore inside a single `k3s` process, without the metrics endpoints the chart expects. With the defaults, those four targets would always be down and their alerts (`KubeSchedulerDown`, `KubeControllerManagerDown`…) would fire forever. An alert that is always firing teaches everyone to ignore alerts, so the solution disables those components and their rules.

### Pod Security

node-exporter reads the host's `/proc`, `/sys` and root filesystem, and uses the host network and PID namespace. The `monitoring` namespace therefore carries the `privileged` Pod Security level. That is a deliberate trade-off: the namespace holds only the monitoring stack, and only cluster admins can create workloads in it.

---

## What to Measure: USE and RED

Two short methods cover most of what is worth putting on a dashboard:

| Method | For | Signals | Where in this phase |
|---|---|---|---|
| **USE** (Brendan Gregg) | Resources: CPU, memory, disks, network | **U**tilization, **S**aturation, **E**rrors | node-exporter and the chart's *Node Exporter* and *Compute Resources* dashboards |
| **RED** (Tom Wilkie) | Services that answer requests | **R**ate, **E**rrors, **D**uration | The todo-app dashboard, from the backend's own metrics |

Google's **four golden signals** (latency, traffic, errors, saturation) are the same idea. The point of all three is to start from what users experience, not from every number a system can export.

The Envoy proxies in front of every route add a second, free RED view: `infrastructure/configs/gateway/pod-monitor.yaml` scrapes them, so request rates and response codes per route exist even for services that export no metrics of their own.

---

## Instrumenting the Application

Platform metrics say nothing about the business logic. In this phase the todo-app backend is instrumented with [prom-client](https://github.com/siimon/prom-client), the standard Prometheus client for Node.js:

| Metric | Type | Labels | Answers |
|---|---|---|---|
| `http_requests_total` | Counter | `method`, `route`, `status_code` | Rate and errors |
| `http_request_duration_seconds` | Histogram | `method`, `route`, `status_code` | Duration (p50, p95…) |
| `process_*`, `nodejs_*` | Default metrics | — | CPU, memory, event loop lag, garbage collection |

An Express middleware records every request when the response finishes, and the metrics are served on `/metrics`, outside `/api/v1`. The frontend only proxies `/api/v1*`, so `/metrics` is reachable from inside the cluster but not from `https://todo.local`. Metrics often reveal more about a system than you want on the internet.

The chart (version `0.2.0`) adds what Prometheus needs to find the endpoint: a named port (`http`) on the backend Service, and an optional `ServiceMonitor` template enabled with `backend.metrics.serviceMonitor.enabled`. The template is off by default, because rendering a `ServiceMonitor` in a cluster without the CRDs would fail. Most charts follow this convention.

### Structured logs

The same middleware writes one JSON line per request:

```json
{"level":"info","msg":"request","method":"GET","path":"/api/v1/","route":"/api/v1/","status_code":200,"duration_ms":4}
```

LogQL can parse a JSON log line at query time (`| json`) and filter it by field (`status_code >= 500`) without regular expressions. JSON lines cost nothing extra to write, and they give logs and metrics the same vocabulary (`route`, `status_code`), so you can go from a spike on a graph to the exact requests behind it.

### Logs are data, and data leaks

Before this phase the backend printed its full `DATABASE_URI` on startup, PostgreSQL password included. On a laptop that is a bad habit. With Alloy shipping every line to Loki, it means **anyone who can open Grafana can read the database password**. The backend now logs only host, port and database name.

Centralising logs changes who can read them. Treat every log line as if it were published to everyone with dashboard access: no passwords, tokens, session cookies or personal data.

---

## Logs: Loki and Alloy

### Loki indexes labels, not content

Elasticsearch-style systems build a full-text index of every word of every log line, which makes any search fast and storage expensive. **Loki** takes the Prometheus approach instead. It indexes only a small set of **labels** (`namespace`, `pod`, `container`, `app`, `node`), groups lines with identical labels into **streams**, and stores the lines compressed in **chunks**. A query first selects streams by label, then scans their content:

```logql
{namespace="todo", container="backend"} |= "error"
{namespace="todo", container="backend"} | json | status_code >= 500
sum by (route) (count_over_time({namespace="todo"} | json [5m]))
```

The cardinality rule applies again, even more strictly: every unique label set is a new stream, and Loki works best with a few thousand of them. Pod names are fine, because they change only on rollouts. Request IDs, user IDs or paths are not. Those belong in the log line, where `| json` can reach them.

### Deployment modes

| Mode | Shape | Storage | When |
|---|---|---|---|
| **Monolithic** | All components in one process | Local filesystem or object storage | Up to ~20 GB of logs per day: this homelab |
| **Simple scalable** | Separate read, write and backend targets | Object storage (S3, GCS, MinIO) required | Hundreds of GB per day |
| **Microservices** | Every component deployed separately | Object storage | Very large installations |

The solution uses monolithic mode with chunks and index on a Longhorn volume and a 7-day retention enforced by the compactor. It runs no caches and no gateway, because those components only pay off in the scalable modes.

### Alloy collects

**Grafana Alloy** is the collector: it discovers what to collect, adds labels, and forwards to a backend. It replaces Promtail, which reached end of life in March 2026. Its configuration is a pipeline of components:

1. `discovery.kubernetes` finds the Pods running **on this node** (Alloy runs as a DaemonSet, one Pod per node, each with a field selector on its own node name)
2. `discovery.relabel` turns Kubernetes metadata into the five Loki labels
3. `loki.source.kubernetes` follows the containers' logs through the Kubernetes API, the same stream as `kubectl logs`
4. `loki.write` pushes them to Loki

Because Alloy reads through the API instead of from `/var/log/pods` on the host, it needs no `hostPath` mounts and no privileges. The cost is on the node: the kubelet serves each followed stream by watching the container's log file with inotify, one instance per container. With the default limit of 128 instances per user, a node with a few dozen containers runs out, and the kubelet starts writing `failed to create fsnotify watcher: too many open files` into the streams themselves. Kubernetes nodes usually raise `fs.inotify.max_user_instances`; `docs/cluster-setup/k3s.md` does it.

Alloy can also scrape metrics, receive OpenTelemetry data and much more. Here it does **only logs**: Prometheus already scrapes the metrics through `ServiceMonitor`s, and having two systems scrape the same targets would double the data and the confusion.

---

## Alerting

An **alerting rule** is a PromQL expression plus a duration:

```yaml
- alert: KubePodCrashLooping
  expr: max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1
  for: 15m
  labels:
    severity: warning
```

Prometheus evaluates every rule periodically. When the expression returns results, the alert becomes **pending**. If it keeps returning them for the whole `for` duration, it becomes **firing** and Prometheus sends it to Alertmanager. The `for` clause is what keeps a Pod that restarts once from paging anybody.

**Alertmanager** decides what happens next. It **groups** related alerts into one notification, **inhibits** less important alerts while a more important one fires, lets humans **silence** alerts during maintenance, and **routes** each group to a receiver (email, Slack, Discord, PagerDuty…).

This phase uses the chart's default rules and configures **no receivers**: alerts are visible in Grafana (*Alerting → Alert rules*) and in the Alertmanager UI, but nobody is notified. Notifications need a credential (a webhook URL, an SMTP password), which in this platform means a SealedSecret. That is left as an additional exercise.

One alert always fires on purpose: `Watchdog`. It proves the whole alerting pipeline works. In production it is sent to an external "dead man's switch" service, which alerts *you* when the Watchdog stops arriving.

---

## Grafana as Code

You could configure Grafana by clicking: add a datasource, build a dashboard, invite users. All of that would live in Grafana's database and disappear with it, which is exactly the hand-made state Phase 09 removed from the cluster. Here, everything Grafana shows comes from Git:

| What | How |
|---|---|
| **Datasources** | Prometheus and Alertmanager added by the chart; Loki declared in `additionalDataSources` with a fixed `uid` that dashboards can reference |
| **Dashboards** | Plain `.json` files in `monitoring/kube-prometheus-stack/dashboards/`, turned into ConfigMaps labelled `grafana_dashboard: "1"` by a Kustomize `configMapGenerator`; a sidecar container in the Grafana Pod loads them, and the `grafana_folder` annotation picks the folder |
| **Users and roles** | Created on first login from authentik, with the role derived from authentik groups |
| **Configuration** | `grafana.ini` values in the `HelmRelease` |

Keeping dashboards as `.json` files, instead of JSON pasted inside a ConfigMap, matches the workflow: you export a dashboard from the Grafana UI and save it over the file, and the diff in the pull request is the dashboard change. The official [flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example) uses the same generator.

As a result, Grafana keeps **no state worth backing up**, so persistence is disabled. You can still edit a provisioned dashboard in the UI to experiment. To keep the change, export the JSON and commit it, because a restart discards anything that was not committed.

---

## Single Sign-On with OIDC

Phase 07 protected applications that have no login of their own (the todo-app, the Longhorn UI) with **forward-auth**: the Gateway asks the authentik outpost before letting each request through. Grafana has its own users and roles, so it uses the other integration authentik offers: **OpenID Connect**.

1. You open `https://grafana.local` and click *Sign in with authentik*
2. Grafana redirects the browser to authentik's authorize endpoint, with a PKCE challenge
3. You log in to authentik (or are already logged in) and are redirected back to `https://grafana.local/login/generic_oauth` with a one-time code
4. **Grafana's server**, not your browser, exchanges the code for tokens at `https://authentik.local/application/o/token/`, proving its identity with the **client secret**
5. Grafana reads the user's `groups` claim and maps it to a role: *authentik Admins* → Admin, *Grafana Editors* → Editor, everybody else → Viewer

Step 4 runs inside a Pod, so it meets the same two problems Flux had with Harbor in Phase 09, and they are solved the same way:

- **DNS**: `authentik.local` must resolve in the cluster, which the `coredns-custom` ConfigMap already does. `grafana.local` is added there too, so every homelab hostname resolves from any Pod.
- **TLS**: Grafana must trust the homelab CA. A small `Certificate` in `monitoring` provides the public CA in its `ca.crt` key, which is mounted into Grafana and referenced by `tls_client_ca`.

### authentik blueprints

In Phase 07 you created the authentik providers by clicking in the admin UI, and Phase 09 listed them under *What stays imperative*. **Blueprints** are authentik's declarative configuration: YAML files describing providers, applications, groups or flows, which the worker applies on startup and whenever the file changes. `platform/authentik/blueprint-grafana.yaml` declares the Grafana OAuth2 provider, the application and the *Grafana Editors* group, and the authentik `HelmRelease` mounts it into the worker. The Grafana integration is the first authentik configuration that lives in Git.

### One secret, two namespaces

Both ends of the OIDC exchange need the same client secret: authentik to verify it, Grafana to present it. A SealedSecret is encrypted for one namespace and name, which is part of what makes it safe to publish. So `seal-platform-secrets.sh` seals the same value twice, as `grafana-oidc` in `authentik` and in `monitoring`. The blueprint reads it with `!Env` from the worker's environment, and Grafana reads it as an environment variable as well. The secret never appears in either file.

### What is not exposed

Only Grafana gets an `HTTPRoute`. The Prometheus and Alertmanager UIs have no authentication at all, and everything they show is available in Grafana (*Explore*, *Alerting*) behind the authentik login. For a direct look, `kubectl port-forward` is enough: if you can reach the API server, you were already trusted.

---

## Where the Stack Lives in the Repository

Phase 09 follows the layout of [flux2-kustomize-helm-example](https://github.com/fluxcd/flux2-kustomize-helm-example): `infrastructure/{controllers,configs}`, `apps/{base,prod}` and `clusters/`, plus the `platform-secrets/` and `platform/` layers this homelab needs. Phase 10 adds **one layer, `monitoring/`**, as the official [flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example) does. Everything else goes where a component of its kind already lives:

| Piece | Location | Why there |
|---|---|---|
| Prometheus Operator CRDs | `infrastructure/controllers/prometheus-operator-crds/` | CRDs belong to the first layer, so every later layer can use them |
| Flux and Envoy monitors | `infrastructure/configs/flux/`, `infrastructure/configs/gateway/` | Custom resources configuring infrastructure components, next to the rest of their configuration |
| kube-prometheus-stack, Loki, Alloy | `monitoring/<component>/` | Their own layer, after `platform-secrets` and `infra-configs`, with nothing depending on it (see below) |
| Grafana route, CA bundle, dashboards | `monitoring/kube-prometheus-stack/` | They belong to Grafana, which this release installs |
| Grafana OIDC secret, `monitoring` namespace | `platform-secrets/` | Same as the other credentials |

### Why its own layer?

Monitoring sounds like infrastructure, and in many clusters it is installed with the other controllers. Here it cannot be, because of the dependency chain:

1. Grafana needs the `grafana-oidc` Secret to start
2. That Secret is a SealedSecret applied by `platform-secrets`
3. `platform-secrets` depends on `infra-controllers`, because the Sealed Secrets controller is installed there

If kube-prometheus-stack were in `infra-controllers` (with `wait: true`), the layer would wait for a Grafana Pod that waits for a Secret that is only applied after the layer is Ready: a deadlock.

The `platform` layer sits after `platform-secrets` and `infra-configs` (Gateway, CA issuer, storage), which is what the stack needs, so it looks like the obvious home. It is not, because of who depends on `platform`: `apps` and `image-automation`. With `wait: true`, `platform` is only Ready when *every* release inside it is healthy, so a Grafana Pod that runs out of memory or a Loki volume that cannot be attached would stop every application release until someone fixes the monitoring. Observability must watch the platform, not gate it.

So the stack gets its own `monitoring` Flux `Kustomization`, with the same two dependencies as `platform` and **nothing depending on it**. It comes up in parallel with authentik and Harbor, and if it breaks, deliveries carry on.

The same reasoning decides what goes inside `monitoring/kube-prometheus-stack/`. The Grafana CA bundle `Certificate` lives with the release, not in a later step, because the Grafana Pod mounts its Secret and cannot start without it. The `HelmRelease` would never become Ready if it waited for something applied after it.

---

## The Layer Model, Updated

| Layer | Change in Phase 10 |
|---|---|
| **infra-controllers** | New `prometheus-operator-crds` release; cert-manager and Longhorn ship `ServiceMonitor`s and depend on it |
| **infra-configs** | `ServiceMonitor`/`PodMonitor` for Flux and the Envoy proxies; `grafana.local` added to the Gateway certificate and to CoreDNS |
| **platform-secrets** | The `monitoring` namespace joins `authentik` and `harbor` in `namespaces.yaml`; the two `grafana-oidc` secrets |
| **platform** | authentik and Harbor expose metrics; authentik applies the Grafana blueprint |
| **monitoring** (new) | kube-prometheus-stack, Loki and Alloy; depends on `infra-configs` and `platform-secrets`, and nothing depends on it |
| **apps** | Chart `0.2.0` and backend `1.1.0` with a `ServiceMonitor` |

The dependency graph gains a branch, not a step: `monitoring` runs beside `platform`, so a rebuild takes no longer to reach the todo-app, and an unhealthy monitoring stack shows up as one layer that is not Ready while every other layer keeps reconciling.

### Namespaces in `platform-secrets`

A namespace belongs to the earliest layer that puts something into it. `platform-secrets` applies SealedSecrets into `authentik`, `harbor` and now `monitoring`, so the three namespaces live in `platform-secrets/namespaces.yaml`. If they were declared with their HelmReleases, a clean cluster would never start: `platform-secrets` would fail on a missing namespace, and the layers that would create it wait for `platform-secrets` to be Ready. Flux applies Namespaces before any other object of the same Kustomization, so one layer is enough.

Early versions of Phase 09 declared `authentik` and `harbor` in `platform/`. Moving an object between Kustomizations on a running cluster is the one GitOps change that needs care. With `prune: true`, the old owner wants to garbage-collect what disappeared from its path, and deleting a namespace deletes everything in it, PersistentVolumeClaims included. Flux only prunes objects that still carry its own ownership labels, and `dependsOn` makes `platform-secrets` apply (and relabel) the namespaces before `platform` reconciles the new revision, so the move is safe. Additional exercise 12 in `tasks.md` still adds a safety net.

---

## Resources and Retention

The observability stack is often the largest workload of a small cluster. The solution sets explicit requests, limits and retention for every component:

| Component | Memory request / limit | Storage | Retention |
|---|---|---|---|
| Prometheus | 1 Gi / 2 Gi | 10 Gi | 10 days or 8 GB, whichever comes first |
| Grafana | 256 Mi / 1 Gi | None | — |
| Loki | 256 Mi / 1 Gi | 5 Gi | 7 days |
| Alertmanager, kube-state-metrics, Alloy | 64 Mi / 256 Mi each | — | — |

`retentionSize` is set below the volume size on purpose: a full TSDB volume stops Prometheus, while a size-based retention deletes the oldest blocks first.

Limits that are too tight fail in confusing ways. Grafana 13 uses about 450 Mi right after startup. With a 512 Mi limit it was not killed, but the Go garbage collector ran continuously and used a full CPU, so the UI timed out behind the Gateway with a 504. If a component is slow rather than crashing, compare its memory with its limit before anything else.

---

## Further Reading

- [Prometheus documentation](https://prometheus.io/docs/): data model, metric types, PromQL
- [Prometheus naming best practices](https://prometheus.io/docs/practices/naming/) and [instrumentation](https://prometheus.io/docs/practices/instrumentation/)
- [Prometheus Operator API](https://prometheus-operator.dev/docs/api-reference/api/): `ServiceMonitor`, `PodMonitor`, `PrometheusRule`
- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Loki documentation](https://grafana.com/docs/loki/latest/): labels, deployment modes, LogQL
- [Grafana Alloy documentation](https://grafana.com/docs/alloy/latest/): components and Kubernetes log collection
- [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/): grouping, inhibition, routing
- [Grafana generic OAuth](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/) and [authentik's Grafana integration](https://integrations.goauthentik.io/monitoring/grafana/)
- [authentik blueprints](https://docs.goauthentik.io/customize/blueprints/)
- [The RED method](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/) and [the USE method](https://www.brendangregg.com/usemethod.html)
- [Google SRE book: Monitoring distributed systems](https://sre.google/sre-book/monitoring-distributed-systems/): the four golden signals
- [flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example): Flux's own reference for kube-prometheus-stack, dashboards and Flux metrics
- [Flux Operator monitoring](https://fluxcd.control-plane.io/operator/monitoring/): the `flux_resource_info` metric
