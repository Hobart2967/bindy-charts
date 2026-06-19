# bindy-charts

Unofficial community Helm charts for the [Bindy](https://github.com/firestoned/bindy) BIND9 Kubernetes Operator.

Charts are automatically synced from upstream Bindy releases and published via GitHub Pages.

## Charts

| Chart | Type | Description |
|---|---|---|
| `bindy-crds` | application | CustomResourceDefinitions for the Bindy API group `bindy.firestoned.io` |
| `bindy` | application | The Bindy BIND9 Kubernetes Operator |

> **Install order:** `bindy-crds` must be installed before `bindy`. The CRDs must exist in the cluster before the operator starts.

## Repository

```bash
helm repo add bindy-charts https://hobart2967.github.io/bindy-charts
helm repo update
```

## Installing with Helm

```bash
# 1 — CRDs (install first, or upgrade separately)
helm install bindy-crds bindy-charts/bindy-crds \
  --namespace bindy-system \
  --create-namespace

# 2 — Operator
helm install bindy bindy-charts/bindy \
  --namespace bindy-system \
  --create-namespace
```

## Installing with Helmfile

Create a `helmfile.yaml` in your infrastructure repository:

```yaml
repositories:
  - name: bindy-charts
    url: https://hobart2967.github.io/bindy-charts

releases:
  # ── 1. CRDs ────────────────────────────────────────────────────────────────
  # Must be installed before the operator. Use a dedicated namespace so CRDs
  # can be managed independently of the operator lifecycle.
  - name: bindy-crds
    namespace: bindy-system
    createNamespace: true
    chart: bindy-charts/bindy-crds
    version: "~0.5"           # pin to a minor range; bump deliberately
    disableValidation: true   # CRDs are cluster-scoped — skip namespace check

  # ── 2. Operator ────────────────────────────────────────────────────────────
  - name: bindy
    namespace: bindy-system
    createNamespace: true
    chart: bindy-charts/bindy
    version: "~0.5"
    needs:
      - bindy-system/bindy-crds
    values:
      - namespace: bindy-system
        replicas: 1
        image:
          repository: ghcr.io/firestoned/bindy
          tag: ""             # tracks Chart.appVersion
          pullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        leaderElection:
          enabled: "true"
          leaseName: bindy-leader
          leaseDurationSeconds: "15"
          renewDeadlineSeconds: "10"
          retryPeriodSeconds: "2"
        log:
          level: info
          format: text
```

Apply with:

```bash
helmfile sync
```

### HA / production example

```yaml
releases:
  - name: bindy-crds
    namespace: bindy-system
    createNamespace: true
    chart: bindy-charts/bindy-crds
    version: "~0.5"
    disableValidation: true

  - name: bindy
    namespace: bindy-system
    createNamespace: true
    chart: bindy-charts/bindy
    version: "~0.5"
    needs:
      - bindy-system/bindy-crds
    values:
      - replicas: 3           # leader election keeps only one active pod
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        leaderElection:
          enabled: "true"
          leaseName: bindy-leader
          leaseDurationSeconds: "15"
          renewDeadlineSeconds: "10"
          retryPeriodSeconds: "2"
        log:
          level: warn
          format: json
```

## Custom Resources

After the operator is running, you can manage DNS via Kubernetes resources in the `bindy.firestoned.io` API group.

| Kind | Short name(s) | Scope | Description |
|---|---|---|---|
| `DNSZone` | `zone`, `zones`, `dz` | Namespaced | A DNS zone managed by a Bind9 instance |
| `Bind9Instance` | `b9`, `b9s` | Namespaced | A BIND9 server instance |
| `Bind9Cluster` | — | Namespaced | A cluster of Bind9 instances |
| `ClusterBind9Provider` | — | Cluster | Cluster-wide DNS provider reference |
| `ARecord` | `a` | Namespaced | DNS A record |
| `AAAARecord` | — | Namespaced | DNS AAAA record |
| `CNAMERecord` | — | Namespaced | DNS CNAME record |
| `MXRecord` | — | Namespaced | DNS MX record |
| `TXTRecord` | — | Namespaced | DNS TXT record |
| `NSRecord` | — | Namespaced | DNS NS record |
| `SRVRecord` | — | Namespaced | DNS SRV record |
| `CAARecord` | — | Namespaced | DNS CAA record |

## Chart configuration (`bindy`)

| Parameter | Default | Description |
|---|---|---|
| `namespace` | `dns` | Namespace to deploy the operator into |
| `createNamespace` | `true` | Create the namespace if it does not exist |
| `image.repository` | `ghcr.io/firestoned/bindy` | Operator image repository |
| `image.tag` | `""` | Image tag — defaults to `Chart.appVersion` |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `replicas` | `1` | Number of operator replicas |
| `resources.requests.cpu` | `100m` | CPU request |
| `resources.requests.memory` | `128Mi` | Memory request |
| `resources.limits.cpu` | `500m` | CPU limit |
| `resources.limits.memory` | `512Mi` | Memory limit |
| `leaderElection.enabled` | `"true"` | Enable leader election (required for `replicas > 1`) |
| `leaderElection.leaseName` | `bindy-leader` | Lease lock name |
| `leaderElection.leaseDurationSeconds` | `"15"` | Leader lease duration |
| `leaderElection.renewDeadlineSeconds` | `"10"` | Leader renewal deadline |
| `leaderElection.retryPeriodSeconds` | `"2"` | Follower retry interval |
| `log.level` | `info` | Log level (`debug`, `info`, `warn`, `error`) |
| `log.format` | `text` | Log format (`text`, `json`) |
| `nameOverride` | `""` | Override the chart name |
| `fullnameOverride` | `""` | Override the full release name |

## Versioning

Chart versions mirror the upstream Bindy release tag (e.g. Bindy `v0.5.2` → chart version `0.5.2`). Charts are updated automatically each day via a scheduled GitHub Actions workflow.

## Sources

- Upstream operator: <https://github.com/firestoned/bindy>
- Chart source: <https://github.com/Hobart2967/bindy-charts>
