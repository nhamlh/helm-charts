# posthog

A minimal Helm chart for self-hosting PostHog on Kubernetes.

## Design principles

- **External dependencies only** — Postgres, Redis, ClickHouse, Kafka, and S3
  are managed outside the chart and configured via `values.yaml`. No stateful
  services are provisioned in-cluster.
- **Minimal by default** — the default install deploys only the components
  needed for product analytics event ingestion + UI (7 Deployments, 2 Jobs).
- **Feature gates** — optional components (session replay, error tracking, CDP,
  Temporal, etc.) are toggled via `features.*.enabled` flags. Enable them as
  your needs grow.
- **Single-node ClickHouse** — configured for standalone `MergeTree` engines,
  no ZooKeeper or replication required. Suitable for evaluation and light
  workloads.

## Minimal stack (default)

| Component | Image | Purpose |
|---|---|---|
| `web` | `posthog` (Django) | App server, API, UI |
| `worker` | `posthog` (Django) | Celery async jobs |
| `capture` | `posthog/capture` (Rust) | Event ingestion → Kafka |
| `ingestion-general` | `posthog-node` (Node.js) | Kafka → ClickHouse pipeline |
| `feature-flags` | `posthog/feature-flags` (Rust) | Flag evaluation endpoint |
| `personhog-replica` | `posthog/personhog-replica` (Rust) | Person/group data read-write |
| `personhog-router` | `posthog/personhog-router` (Rust) | gRPC proxy to personhog-replicas |
| `migrate` (Job) | `posthog` (Django) | DB schema migrations |
| `kafka-init` (Job) | `redpanda` | Kafka topic bootstrap |

## Optional features

| Feature flag | Components added |
|---|---|
| `features.sessionReplay.enabled` | `replay-capture`, `ingestion-sessionreplay`, `recording-api` |
| `features.errorTracking.enabled` | `ingestion-error-tracking`, `cymbal` |
| `features.logs.enabled` | `ingestion-logs` |
| `features.traces.enabled` | `ingestion-traces` |
| `features.aiCapture.enabled` | `capture-ai` |
| `features.captureLogs.enabled` | `capture-logs` (OTLP) |
| `features.propertyDefs.enabled` | `property-defs-rs` |
| `features.cdp.enabled` | `plugins`, `cyclotron-janitor` |
| `features.temporal.enabled` | `temporal-django-worker` (requires external Temporal server) |
| `features.hypercache.enabled` | `hypercache-server` |
| `features.livestream.enabled` | `livestream` |

## Prerequisites

- Kubernetes 1.28+
- Helm 3.0+
- [Gateway API CRDs](https://gateway-api.sigs.k8s.io/guides/#installing-gateway-api) installed in the cluster
- A `Gateway` resource provisioned separately (TLS, hostname, listener config)
- External services reachable from the cluster:
  - **PostgreSQL** ≥11, ≤14 (main DB + optional persons DB)
  - **Redis** ≥7.0, <8.0
  - **ClickHouse** ≥24.8, ≤25.12 (single standalone node)
  - **Kafka** (any broker — MSK, WarpStream, self-hosted)
  - **S3-compatible object storage** (optional but recommended)

## Quick start

```bash
# 1. Create a values file with your external service endpoints
cat > my-values.yaml <<EOF
secrets:
  secretKey: "your-unique-secret-key-here"
  encryptionSaltKeys: "your-32-byte-fernet-key-here"
  internalApiSecret: "your-internal-api-secret"

siteUrl: "https://posthog.example.com"

gateway:
  httpRoute:
    enabled: true
    parentRef:
      name: "my-gateway"

postgres:
  url: "postgres://posthog:password@postgres.example.com:5432/posthog"

redis:
  url: "redis://:password@redis.example.com:6379"

clickhouse:
  host: "clickhog.example.com"
  password: "your-clickhouse-password"

kafka:
  hosts: "kafka.example.com:9092"

objectStorage:
  enabled: true
  endpoint: "https://s3.amazonaws.com"
  accessKeyId: "AKIAIOSFODNN7EXAMPLE"
  secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  bucket: "posthog"
  region: "us-east-1"
EOF

# 2. Install the chart
helm install posthog ./posthog -f my-values.yaml -n posthog --create-namespace

# 3. Open SITE_URL in a browser and complete /signup to create the first admin user
```

## Enabling features

Add feature flags to your values file:

```yaml
features:
  sessionReplay:
    enabled: true
    s3:
      endpoint: "http://seaweedfs:8333"
      accessKeyId: "any"
      secretAccessKey: "any"
      bucket: "posthog"

  errorTracking:
    enabled: true

  temporal:
    enabled: true
    host: "temporal.example.com"
    port: 7233
    namespace: "default"
    secretKey: "your-temporal-encryption-key"
```

Then upgrade:

```bash
helm upgrade posthog ./posthog -f my-values.yaml -n posthog
```

## Gateway / HTTPRoute

The chart uses the **Gateway API** (`HTTPRoute`) instead of `Ingress`.
TLS termination is handled by the Gateway infrastructure (not this chart) —
create a `Gateway` resource separately and reference it via `parentRefs`.

Path-based routing mirrors the Caddy proxy from
`docker-compose.base.yml`:

| Path | Backend |
|---|---|
| `/e`, `/i/v0`, `/batch`, `/capture` | `capture` |
| `/flags`, `/api/feature_flag/local_evaluation` | `feature-flags` |
| `/` (catch-all) | `web` |

Additional paths for optional features (replay-capture, capture-ai,
capture-logs, hypercache, livestream, plugins) are added automatically when
the corresponding feature flags are enabled.

More-specific paths are ordered before catch-all prefixes so the Gateway
controller evaluates them first (e.g. `/i/v0/ai` before `/i/v0`).

```yaml
gateway:
  httpRoute:
    enabled: true
    parentRef:
      name: "my-gateway"
      namespace: "infra"
      sectionName: "https"
```

### Example Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: infra
spec:
  gatewayClassName: nginx
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      hostname: posthog.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: posthog-tls
```

## ClickHouse: standalone setup

This chart configures ClickHouse for **single-node standalone** operation:

- `CLICKHOUSE_CLUSTER` is set to `posthog` (1 shard / 1 replica)
- No ZooKeeper / clickhouse-keeper required
- Tables use `MergeTree` engines (not `ReplicatedMergeTree`)
- Suitable for evaluation and light workloads

For production HA, run a managed ClickHouse cluster externally and point
`clickhouse.*` values at it. Set `clickhouse.cluster` to your cluster name.

## Secrets

**Never use default values in production.** All secrets must be unique per
installation:

| Secret | Purpose |
|---|---|
| `secrets.secretKey` | Django crypto signing |
| `secrets.encryptionSaltKeys` | Fernet key for encrypted fields (exactly 32 bytes) |
| `secrets.internalApiSecret` | Django ↔ Node.js internal auth |
| `secrets.jwtSecret` | JWT for capture-logs (required if `features.captureLogs.enabled`) |

## Architecture reference

See [`docs/internal/self-hosting-kubernetes-architecture.md`](../../docs/internal/self-hosting-kubernetes-architecture.md)
for the full component dependency graph, env var reference, and migration
ordering details.

## Values reference

See [values.yaml](./values.yaml) for the complete configuration surface with
inline comments.
