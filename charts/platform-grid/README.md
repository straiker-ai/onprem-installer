# grid — Helm chart

Deploys the Grid read/query service (`/api/v3/inventory|activity|insights`) — a
CH-only reader over the ClickHouse serving layer + the registry-mastered dimension
CDC replicas. Mirrors the `foundation` chart (plain HTTP service: SA + config +
service + deployment + hpa), plus a ClickHouse config block. Grid owns no Postgres
schema (the registry service does); its only migration hook applies the ClickHouse
schema, and it is off by default (see Migrations).

## How it deploys

Driven by the shared `CI.yml` / `CD.yml` reusable workflows (see
`.github/workflows/`). Release name and values key are `grid`:

- Chart path: `services/grid/deploy/helm/grid`
- Dev values: `values/values-dev.yaml`
- Image: `…/straiker/grid:<tag>` (tag injected by CD `--set straiker.grid.image.version`)

**Dev (manual, no merge):** Actions → _Deploy branch to dev_ → pick branch +
`grid`. CD builds `straiker/grid:<sha>` into the dev ECR and `helm upgrade`s it.

**Pipeline:** `grid` (test+lint+build) gates `grid-ci` (image build), then
`grid-cd` runs the shared CD workflow. Main deploys through dev and stage. Release
tags also promote to production in us-east-1 and then ap-northeast-2.

## Required before the first deploy

### 1. Secrets — add these keys to the env `platform` Secrets Manager blob

The pod consumes the shared `platform-secret` (synced by ESO from `{env}/platform`)
via `envFrom`. Grid needs these **`GRID_`-prefixed** keys added to that blob
(non-secret settings — database name, TLS, timeouts — are in the ConfigMap):

| key                        | value (dev)                                    |
| -------------------------- | ---------------------------------------------- |
| `GRID_CLICKHOUSE_ADDR`     | `<svc-id>.us-east-1.aws.clickhouse.cloud:9440` |
| `GRID_CLICKHOUSE_USERNAME` | `grid_query_ro` (see note)                     |
| `GRID_CLICKHOUSE_PASSWORD` | …                                              |

> Grid is **CH-only** (R1): it holds no Postgres pool and needs no DB DSN. The
> estate dims are mastered by the **registry** service (its own PG SoT) and reach
> grid as the CDC replicas in ClickHouse.

> The service **degrades gracefully** if the CH keys are absent — it still serves
> `/healthz`; CH-backed reads return 502 — so a deploy won't crashloop before the
> keys land. It just won't serve data.

> **CH user:** only the `default` user exists on grid-dev today (see
> `deploy/ch/.env.local`). Create the read-only `grid_query_ro` role (INFRA.md §1)
> and use it here rather than `default`.

### 2. Identity — `platform-sa` (already exists)

The chart references `platform-sa` (EKS Pod Identity, infra-managed) and does not
create it. The query plane needs no AWS perms beyond reading the ESO-synced
`platform-secret` (a plain k8s Secret), so no new role/policy is required. If a
later feature needs S3 presign (evidence artifacts), grant that on the SA then.

### 3. Network (already open)

- **ClickHouse:** reached over the public TLS endpoint (`:9440`, `secure: true`);
  reachable from the cluster today. PrivateLink is the eventual hardening (INFRA.md §1).

## Sentry

**Presence of `GRID_SENTRY_DSN` is the switch.** With no DSN there is nowhere to
report, so reporting is off; the application default is empty and the Helm values
opt each deployed environment in. There is no separate `enabled` flag for the two
to disagree about.

The DSN is not a secret. It is a write-only ingest key — Sentry ships DSNs in
browser bundles — so it lives in the ConfigMap with the other non-secret settings
rather than in the platform-secret.

| deployment          | `GRID_ENVIRONMENT` | Sentry |
| ------------------- | ------------------ | ------ |
| local               | `development`      | off    |
| dev                 | `development`      | on     |
| stage               | `staging`          | on     |
| prod                | `production`       | on     |
| prod ap-northeast-2 | `production-apne2` | on     |

`GRID_ENVIRONMENT` becomes Sentry's environment, and it is the **only** thing
separating the two production deployments — same image, same config, different
region. Hence `production-apne2` rather than a second `production`: filter on both
to see all of production. Note this value is also a zap log field, so log queries
pinned to `environment=production` need widening.

All environments report to one project. Sentry's own model is one project per
service, sliced by environment — a project per environment would fragment issue
history across deployments of the same code.

Local runs report nothing unless you supply a DSN. To test Sentry locally:

```bash
GRID_SENTRY_DSN='https://...ingest.us.sentry.io/...' go run ./cmd/grid
```

Mind that a local run inherits `GRID_ENVIRONMENT=development`, so its events land
alongside the dev cluster's.

## Migrations

Grid is **CH-only** (R1) and owns no Postgres schema. The estate PG system of
record — entity graph, taxonomy, governance — and its Liquibase changelog moved to
the **registry** service (`services/registry/deploy/db`, applied by the
`registry-migrations` image). Grid reads those dims as the ClickPipes CDC replicas
in ClickHouse.

Grid's own **ClickHouse** schema is goose migrations in `deploy/ch-goose/` (see its
README). `templates/05-migrate-job.yaml` runs them from the `grid-migrations` image
(`deploy/docker/Dockerfile.migrations`) as a pre-install/pre-upgrade hook Job.
It is gated by `straiker.grid.migrations.enabled`, which defaults to **false**.
Enable it per environment only once that cluster is adopted and DDL credentials reach
the Job. Each env values file already sets `migrations.secretsManager` to
`<env>/platform/clickhouse/default-admin`, which `ch-migrate` reads at start-up as the
pod identity. Enabling therefore needs one IAM grant: `secretsmanager:GetSecretValue` on
that secret for `platform-sa`'s role (+ `kms:Decrypt` if it uses a customer-managed key).
The alternatives are `migrations.credentialsSecret.name` (a k8s Secret with the same
keys), or `GRID_CH_MIGRATE_USERNAME` / `GRID_CH_MIGRATE_PASSWORD` in the platform-secret.
The service's read-only user is never reused for DDL.
