# Handover: on-prem installer, data layer + platform services

Repo: `/Users/prernagupta/Desktop/Git_Repo/onprem-installer` (branch `main`; **everything below is uncommitted and nothing has run in AWS**).
Read-only references: `~/Desktop/Git_Repo/infra` (Terragrunt SaaS), `~/Desktop/Git_Repo/platform` (service code + charts), `~/Desktop/Git_Repo/api-gateway` (`straiker-ai/api-gateway`, chart in `deploy/helm/api-gateway`), `~/Desktop/Git_Repo/gitops`.
Also read: `onprem-architecture.md`, `prod-euc1-handoff.md`, `prod-aps1-handoff.md`, `doc/clickhouse-ingestion-design.md`.

## Goal
A customer-run script, same style as `scripts/install-straiker.sh`, that builds the full Straiker stack in the customer's AWS account: EKS + Karpenter (CPU/GPU), platform services, Defend/Ascend, ClickHouse as a pod, Bifrost, GPU models, and an AWS-managed data tier (Aurora PostgreSQL, ElastiCache Serverless Redis, MSK Serverless, EFS, KMS, Secrets Manager). Demo-grade target (~3 days). Frontend runs as a pod.

## Decisions
- Data tier from AWS; only ClickHouse and app services are pods.
- **Descoped:** Cognito (Dex stays), WAF, OpenSearch Service (pod stays), monitoring.
- **Vendor platform charts into this repo** (customers never need `platform` repo access), via sync scripts pinned to a release tag.
- ClickPipes replaced by: Redpanda Connect (Kafka -> ClickHouse) and a `postgresql()` CronJob (Postgres dims -> ClickHouse).
- api-gateway runs in **full mode** with `--data-layer` (DynamoDB + Secrets Manager); read-only mode is the fallback. OAuth/PAT stay in-memory.
- Everything new is opt-in behind `--data-layer`; all new phases are no-ops without it.

## What is built (validated only with validate/lint/template/bash -n and Docker tests)

### Terraform: `terraform/aws/data/` (`terraform validate` passes)
Plain resources, map-keyed inputs, one file per component: `kms aurora elasticache msk efs s3 dynamodb secrets pod_identity locals variables outputs versions providers`.
- Aurora PG Serverless v2 (16.6, RDS-managed master secret; `min` = writer only, `ha/max` = +reader + deletion protection), ElastiCache Serverless Redis 7, MSK Serverless (IAM, 9098, max 3 subnets), EFS `models`, KMS key.
- `s3.tf`: `<cluster>-<acct>-grid-artifacts` (SSE-KMS, TLS-only, public block).
- `dynamodb.tf`: `<cluster>-environment` (pk/sk + `apiKey-index` GSI, KMS, PITR).
- `pod_identity.tf`: `pod_identities` map with `s3_read/s3_write/secret_prefixes_rw/secret_prefixes_read/dynamodb_query/ses_send/assume_roles`.
- Outputs include `s3_bucket_names`, `dynamodb_table_names`, `secret_names`.

### Installer: `scripts/install-straiker.sh`
Phase order (`ALL_PHASES`): `... aws-artifacts, aws-data, artifacts-sync, straiker-system, shared-secrets, clickhouse, data-bootstrap, ch-sync, platform-services, ingest, ai-provider-secrets ...`
- `aws-data`: preflight (>=2 AZs, Aurora version available via `AURORA_ENGINE_VERSION`), writes `terraform.auto.tfvars.json` with pod identities `data-bootstrap`, `platform`, `grid-ingest`, `api-gateway` plus secret `platform/api-gateway` (4 generated keys). Saves metadata (`aurora_endpoint`, `msk_cluster_arn`, `efs_file_system_id`, `data_kms_key_arn`, `grid_artifacts_bucket`, `dynamodb_environment_table`, ...). INFRA_NAMESPACE must resolve before it runs.
- `data-bootstrap`: Secret `straiker-aurora-admin` from RDS master secret, SASL/IAM brokers, patches `SYS__ARGUS_INTERNAL_S2S_KEY` into the shared secret, `helm upgrade --install straiker-data`. Re-run after ClickHouse install so CH keys land in `platform-secret`.
- `clickhouse`, `ch-sync`, `platform-services` (env `PLATFORM_SERVICES`, default `foundation databridge portico api-gateway`; **add `registry grid` to test them**), `ingest` (gated on `grid.raw_event` existing).
- `install_api_gateway` seeds DynamoDB `ENV#1`/`META` (straikerId 1, environmentId 1, apiKey = Secret `api-gateway-env`).

### Charts
- `charts/straiker-data`: `straiker-db-dsn` + `platform-secret` (DSNs, `*_BUS_BROKERS`, generated S2S/validate keys, ClickHouse keys), `platform-sa`, db Job (roles/DBs + `grid_cdc` read-only reader; tested on Postgres 16), MSK topics Job (15 topics, jar from github.com).
- `charts/straiker-clickhouse`: single-node StatefulSet + PVC, users `admin/grid_query_ro/grid_ingest/grid_purge`, Secret `clickhouse-credentials`, `grid` DB Job. Image `clickhouse/clickhouse-server:25.8`.
- `charts/straiker-ch-sync`: 30 tables (`files/cdc_targets.sql`), CronJob every minute, tombstones, hourly OPTIMIZE (Docker-tested).
- `charts/straiker-ingest`: Redpanda Connect streams (`events/findings/audit`), DLQ `<topic>.dlq` (Docker-tested with Redpanda + CH 25.8; MSK IAM untested).
- `charts/platform-{foundation,registry,databridge,grid,portico,connect}`: vendored at `v2026.11.3` (chart version `2026.11.300`), hand-written `values-onprem.yaml` each (env `onprem`, OTel off, 1 replica, databridge on MSK, grid/registry `clickhouse.secure: false`, grid `migrations.enabled: true`).
- `charts/platform-api-gateway`: vendored at `v2.3.12` (only `values/routes.yaml` kept, `*.platform` hosts -> release namespace). `values-onprem.yaml`: full mode, in-memory OAuth/PAT, `singleNamespace`, SA `straiker-api-gateway-sa`.
- `charts/straiker-artifact/values.yaml` + `terraform/aws/artifacts/locals.tf`: added the 6 platform images + `-migrations`, `grid-migrations`, `straiker/api-gateway`, `clickhouse/clickhouse-server:25.8`. Mirror source `631748089429.dkr.ecr.us-east-1.amazonaws.com/onprem-base/straiker/<svc>`.

### Sync scripts
- `scripts/sync-platform-charts.sh vTAG [--platform-repo PATH] [svc...]` (also regenerates `cdc_targets.sql`, updates mirror tags).
- `scripts/sync-api-gateway-chart.sh vX.Y.Z [--repo PATH]`.

## Test steps (first real run; user runs applies). Use a throwaway account/cluster
Prereq: Straiker has copied the new image tags into `onprem-base/` (11 platform images + migrations at `v2026.11.3`, `straiker/api-gateway:v2.3.12`, `clickhouse/clickhouse-server:25.8`). Tools: `aws tofu kubectl helm openssl python3`. Confirm Aurora PG 16.6 exists in the region.

1. **Cluster + mirror**
   ```bash
   AWS_PROFILE=<test> AWS_REGION=eu-central-1 ./scripts/install-straiker.sh --install-eks --data-layer --provision-strategy min --cluster-name dl-test --namespace straiker --straiker-customer-name <name> --straiker-customer-key <key> --yes --phase eks-tfbe,eks-cluster,karpenter,k8s-preflight,aws-artifacts
   ```
2. **Data tier** (Aurora + MSK ~20-30 min each)
   ```bash
   AWS_PROFILE=<test> AWS_REGION=eu-central-1 ./scripts/install-straiker.sh --data-layer --phase aws-data --cluster-name dl-test --namespace straiker
   ```
   Check: `~/.straiker/install.json` metadata keys; `aws eks list-pod-identity-associations --cluster-name dl-test` (SAs `straiker-data`, `platform-sa`, `grid-ingest`, `straiker-api-gateway-sa`); secret `dl-test/platform/api-gateway` has 4 keys.
3. **Images, base, bootstrap**
   ```bash
   AWS_PROFILE=<test> AWS_REGION=eu-central-1 ./scripts/install-straiker.sh --data-layer --phase artifacts-sync,straiker-system,shared-secrets,clickhouse,data-bootstrap,ch-sync --cluster-name dl-test --namespace straiker --straiker-customer-name <name> --straiker-customer-key <key>
   ```
   Check: `kubectl -n straiker get jobs` (db-bootstrap, msk-topics, ch-sync-init complete); db job log shows 7 DBs + `grid_cdc`; topics job log lists 15 topics; `platform-secret` has DSNs, brokers, CH keys.
4. **Platform services**
   ```bash
   PLATFORM_SERVICES="foundation registry databridge portico grid api-gateway" AWS_PROFILE=<test> AWS_REGION=eu-central-1 ./scripts/install-straiker.sh --data-layer --phase platform-services --cluster-name dl-test --namespace straiker
   ```
   Set the same `PLATFORM_SERVICES` on `aws-data` (re-run it) so `platform-sa` gets matching grants. Check pods healthy, migration hook Jobs finished, `SHOW TABLES FROM grid` lists tables (`kubectl -n straiker exec sts/clickhouse -- clickhouse-client --user admin --password <pw from clickhouse-credentials>`), api-gateway log has no AccessDenied.
5. **Ingestion**: `--phase ingest`; produce a sample message or send Defend traffic; rows appear in `grid.raw_event` / `grid.audit_event`; DLQ topics stay empty.
6. **Smoke**: port-forward api-gateway, call `/api/v3/...` with `api-gateway-env` key as Bearer (expect gateway response, not 401); create a resource in registry and watch `grid.resource` populate within ~1 min.
7. **Teardown**: `nuke-eks.sh` does NOT remove data/artifacts/edge stacks. Turn off Aurora/DynamoDB deletion protection if `ha/max`, then `AWS_PROFILE=<test> AWS_REGION=eu-central-1 tofu -chdir=<DATA_DIR> destroy`; delete snapshot `dl-test-aurora-final` by hand; retry on `BucketNotEmpty`.

**Likely first failures:** MSK IAM sign-in/region, Docker Hub + github.com pulls (bootstrap Job images not mirrored), `cp-kafka` CLASSPATH for the IAM jar, grid's real ClickHouse migration, `postgresql()` vs Aurora SSL. Send `kubectl logs` / tofu output to debug.

## Still to do
- **Step 3 real test** (above; user runs).
- **Step 6 (partly done):** `phase_straiker_system` now passes `postgres=null`, `valkey=null`, `efs.enabled=true` + `efs.fileSystemId` (metadata `efs_file_system_id`) and a `models-filestore-pvc` (1Ti) under `--data-layer`, and skips the postgres storage-class override. Verified with `helm template` (scratch copy, Karpenter values off): removes postgres/valkey/postgres-secret objects, adds efs-sc + PV/PVC. **Consumers wired (`--data-layer` only; `helm template` verified, not applied):**
  - `phase_straiker_core`: frontend `db.host` = `aurora_endpoint`, `db.sslMode=require`, password from `straiker-db-dsn` / `PASSWORD_platform`.
  - `phase_straiker_ascend`: `db.host` = `aurora_endpoint`, `db.sslMode=require`, password from `straiker-db-dsn` / `PASSWORD_iris`, `redis.url=rediss://<data_redis_endpoint>:6379`.
  - `phase_straiker_defend`: `redis.url=rediss://<data_redis_endpoint>:6379`.
  - Unverified: whether the iris/argus Redis clients accept `rediss://` (TLS). If not, ElastiCache needs a TLS-terminating path or client change.
  - Unverified: frontend and ascend DB migrations against Aurora with `sslmode=require`.
- **Gate:** new phase `verify-data-layer` (after `ingest`, before `ai-provider-secrets`) checks EFS CSI driver + models PVC Bound, ElastiCache PING over TLS, Aurora `sslmode=require` (iris role), and failed Jobs. Any FAIL blocks the run. Run it after step 4: `--phase verify-data-layer`. Only the Bash syntax and the Jobs filter have been tested; the checks themselves need the cluster.
- **Still open:** EFS CSI driver (`efs.csi.aws.com`) is not installed by any Terraform or script. The models PVC binds statically, but pods mounting it fail until the driver exists. Add an EKS addon or Helm install.
  - Model consumers in the repo don't reference `models-filestore-pvc`; the name mirrors the GKE filestore claim. Confirm against the inference chart.
- **Step 7 later:** Cognito + trigger Lambdas + foundation internal NLB, OpenSearch Service, WAF, `nuke-eks.sh` teardown for data tier (also none for artifacts/edge), upgrade path, update runbook (`docs/new-prod-region-runbook.md`-style) and `onprem-architecture.md`.
- Optional: wire edge route `api.<domain>` -> gateway in `straiker-edge`; verify gateway route upstream names/ports (argus-service, ingest-api, iris-control-plane-service) vs our defend/ascend charts; mirror Docker Hub bootstrap images (`postgres`, `cp-kafka`, `curl`).

## Known gaps / unverified
- Nothing applied: no tofu plan/apply, no real helm installs. MSK IAM auth, multi-broker `${BROKERS}`, Aurora SSL with `postgresql()`, and grid migrations against the real schema are untested.
- Straiker must copy new image tags into `onprem-base/...` (not verified they exist).
- Nothing writes the grid-artifacts bucket on-prem, so transcripts are skeleton-only. Registry CMEK transcripts not set up; SaaS `s6r-<env>-internal-*` probe buckets omitted.
- ClickHouse: storage class uses cluster default (confirm gp3); no backups.
- api-gateway: DynamoDB item shape beyond pk/sk/apiKey/environmentId/straikerId unverified; what `FOUNDATION_API_KEY` pairs with on the foundation side unknown; signing key lives in a ConfigMap (chart design); routes to services absent on-prem (pathfinder, scout, falcon...) 5xx.
- `lint-artifacts.sh` could not run (no `yq`); platform charts only covered by `helm lint`.
- Topics Job downloads the msk-iam-auth jar from github.com (see `doc/egress-allowlist.md`).
- Aurora default 16.6 (SaaS uses 17.x); confirm per region.

## Rules from the user's preferences (keep following)
- User runs `terragrunt/terraform apply`, commits and pushes; do not commit/push unprompted.
- Ask before running commands against any non-Frankfurt cluster, even read-only.
- Terraform style: plain resources, map-keyed extensible inputs, one file per component, SaaS-style naming.
- Automate everything for new-region work; manual steps go in the runbook; keep the runbook updated.
- Apply commands inline: `AWS_PROFILE=prod AWS_REGION=eu-central-1 terragrunt apply`. Compare Frankfurt work against N. Virginia (prod-use1), never Seoul.
- Cross-environment config (e.g. ECR replication) stays manual with console steps in the runbook.
- Concise output style. zsh: quote globs, no word-splitting of unquoted vars, no `timeout`.

## Untracked/modified files from this work
Modified: `charts/straiker-artifact/values.yaml`, `scripts/install-straiker.sh`, `terraform/aws/artifacts/locals.tf`.
New: `terraform/aws/data/`, `charts/{straiker-data,straiker-clickhouse,straiker-ch-sync,straiker-ingest}/`, `charts/platform-{api-gateway,connect,databridge,foundation,grid,portico,registry}/`, `scripts/sync-platform-charts.sh`, `scripts/sync-api-gateway-chart.sh`, `doc/clickhouse-ingestion-design.md`, `handover.md`.
Pre-existing untracked (not mine): `onprem-architecture.md`, `prod-aps1-handoff.md`, `prod-euc1-handoff.md`.
`.terraform.lock.hcl` and `.terraform/` are gitignored; init artifacts were removed from `terraform/aws/data`.

## Resume prompt
"Read `handover.md`, then continue from 'Still to do'. Start with step 6 (straiker-system disables in-cluster Postgres/Valkey and enables EFS under `--data-layer`), or debug whichever test step failed (paste logs)."

## Aurora: one shared cluster, SaaS settings

`terraform/aws/data` builds **one** Aurora PostgreSQL Serverless v2 cluster (`<cluster>-aurora`) shared by every
database (platform services, frontend, iris/Ascend, bifrost), like the SaaS regions. Settings follow the live
Frankfurt (`prod-euc1-cluster-api`) and Mumbai (`prod-aps1-cluster-api`) clusters (read 2026-11-11):

| Setting | SaaS (both regions) | dl-test / installer default |
|---|---|---|
| Engine | aurora-postgresql 17.11, provisioned + db.serverless | same |
| Capacity | 0.5-60 ACU | **2-16 ACU** (change later: edit `aurora_clusters`, rerun `aws-data`; online, no restart) |
| Instances | writer + reader in different AZs, both promotion tier 1 | same (reader in the first AZ that is not the writer's) |
| Parameters | `shared_preload_libraries=pg_stat_statements,pgaudit`, `pgaudit.log=write,ddl`, `rds.logical_replication=1` | same (default of `var.aurora.parameters`) |
| Enhanced Monitoring | 60 s | 60 s (role `<cluster>-rds-monitoring-role` created) |
| Data API | on | on |
| Backup / maintenance window | 03:00-04:00 / Mon 04:00-05:00 UTC | same |
| Backups, IAM auth, Performance Insights, encryption, copy tags | 7 d, on, 7 d, on, on | same |
| Deletion protection | on | by `provision_strategy` (off for `min`) |
| Port | 3306 | 3306 (changing it on an existing cluster restarts it and every consumer must be redeployed; see rollout) |

- Structure: `var.aurora_clusters` is a map (default only `platform`); add a key to split databases onto another cluster
  (`charts/straiker-data` `aurora.clusters.<key>` + `databases.<db>.cluster`). Existing resources moved to `platform`
  with `moved` blocks (no replacement).
- Static parameters need a reboot; `aws-data` reboots instances reporting `pending-reboot` (readers first, writer last).
- `aws-data` records `aurora_other_clusters` plus `aurora_<key>_*` for extra clusters; `platform` keeps the `aurora_*` keys.
- Rollout on an existing install that was on port 5432: `aws-data --rerun-phase` (applies, reboots), `data-bootstrap --rerun-phase`
  (new DSNs + `bifrost` database), `ch-sync`, `straiker-core`, `straiker-ascend`, `platform-services` (all `--rerun-phase`; they now
  take the port from install state), restart the DB-using Deployments (not inference), then `verify-data-layer --rerun-phase`.
- Read-only plan on dl-test: 4 add, 8 change, 0 destroy (cluster, writer, security-group rules updated in place).
- Cost: every instance bills its minimum while idle (2 x 2 ACU) plus Enhanced Monitoring/Performance Insights.

## ClickHouse: 2 replicas + Keeper (diagram topology)

`charts/straiker-clickhouse` now runs **1 shard x 2 replicas** (`replicas: 2`) with a **3-member ClickHouse Keeper**
StatefulSet (`keeper.*`, same clickhouse-server image: it ships `clickhouse-keeper`, so no new image to mirror).

| | Diagram | Chart default |
|---|---|---|
| Servers | 2 replicas, 1 shard, 7 vCPU / 56 GiB / 500 GiB gp3, pool `clickhouse` | same: requests 7 vCPU + 56 GiB, 500 Gi PVC, node pool `straiker-clickhouse` |
| Keeper | 3 x 0.5 vCPU / 1 GiB, pool `general` | same, on the shared pool (label `purpose=general`) |

- Node pool `straiker-clickhouse` (chart `straiker-system`, `karpenter.clickhouse`): arm64 `r6g/r7g.2xlarge` (8 vCPU / 64 GiB),
  tainted `purpose=straiker-clickhouse`. Servers and Keeper members use required anti-affinity (one per node).
- Databases are created as **Replicated** databases (`CREATE DATABASE ... ENGINE = Replicated(...)`, once per replica).
  ClickHouse 25.8 does NOT convert plain `MergeTree` DDL to replicated (`cloud_mode_engine` is a no-op outside Cloud; no in-place
  `MODIFY ENGINE`), so the engines are rewritten for on-prem only:
  - grid migrations: `scripts/patch-platform-grid-replicated.py` adds an init container to `charts/platform-grid`'s migrate Job
    (flag `straiker.grid.migrations.replicatedEngines`, default false = SaaS unchanged); re-applied by `sync-platform-charts.sh`.
  - ch-sync CDC tables: `files/init.sh` rewrites the engines when `clickhouse.replicated=true`.
  - The installer sets both flags from the live StatefulSet (`clickhouse_replicated`).
- DDL (grid migrations, ch-sync) is pinned to replica 0 (`ddlHost` in `clickhouse-credentials`, `GRID_CH_MIGRATE_ADDR`); ch-sync also
  runs there so its INSERT and the tombstone SELECT see the same data. Clients (grid, registry, ingest) use the `clickhouse` Service.
- Verified in a scratch namespace on dl-test (small sizing): 15 grid migrations applied, 52 replicated tables identical on both
  replicas, 13/13 dictionaries load on both (loopback `default` user), 0 read-only replicas, reads keep working with replica 0
  killed and it catches up afterwards. `verify-data-layer` now checks servers, Keeper and read-only replicas.
- Rollout on dl-test (fresh ClickHouse; it holds only test data): `helm uninstall straiker-clickhouse`, delete PVC `data-clickhouse-0`,
  then phases `straiker-system`, `clickhouse`, `data-bootstrap`, `ch-sync`, `platform-services` (grid; uninstall `grid` first so its
  migration reruns on the empty cluster), `ingest`, `verify-data-layer`.
- Cost: 2 x r6g.2xlarge (about $0.40/h each) plus 3 Keeper pods on the shared pool.

## One-command install and runbook

- `scripts/install-data-layer.sh` runs the whole install (pre-flight, `install-straiker.sh` over all phases, resume loop while
  the artifact sync Jobs run, final verification). It reads `~/.straiker/install.json` to tell "waiting" from "needs a person",
  so re-running the same command resumes. Tested on dl-test (no-op resume of a finished install in 2 s), with a stub installer
  for the wait / blocked / crash paths, and for the account and stale-state guards. NOT yet tested: a full install from scratch.
- `doc/data-layer-install-runbook.md` is the handover document (prerequisites incl. the Straiker-side steps, the command,
  recovery, known gaps).

## Iris cache (Valkey node group) and External Secrets (stage 1)

- `aws-data` creates `<cluster>-iris-redis`: Valkey 8.1, 2 × cache.m6g.large, multi-AZ + failover, TLS + AUTH token (generated by Terraform, in state, as in SaaS). Connection JSON (host, port, auth_token, tls, url) is in Secrets Manager `<cluster>/iris/redis`. Defend/Argus keep the serverless cache `main`.
- New phase `external-secrets` (after `aws-data`): ESO 0.14.4 (public chart `charts.external-secrets.io`, public images — a locked-down VPC needs a mirror) plus ClusterSecretStore `aws-sm`. ESO auth is Pod Identity role `<cluster>-eso` (read on `<cluster>/*` + data KMS), created by `aws-data`.
- `straiker-ascend` / `verify-data-layer` apply an ExternalSecret `iris-redis` (keys REDIS_URL/HOST/PORT/AUTH_TOKEN/TLS_ENABLED); chart `straiker-ascend` reads `SYS__REDIS_URL` from it via `redis.existingSecret.name`. A pre-ESO `iris-redis` Secret is deleted once so ESO can own it.
- Rollout order on an existing install: `aws-data --rerun-phase`, `external-secrets`, `straiker-ascend --rerun-phase`, `verify-data-layer --rerun-phase`.
- Next stages: Aurora per-db passwords/DSNs, `platform-secret`, then clickhouse/api-gateway/frontend secrets.

### Stage 2: Aurora role passwords via ESO

- `aws-data` creates Secrets Manager `<cluster>/db/passwords` (one generated key per role: foundation registry databridge connect notify frontend iris bifrost grid_cdc; list = `DB_PASSWORD_ROLES` in the installer, must match chart `straiker-data` databases + readers).
- `data-bootstrap` (`ensure_db_passwords_secret`): on an install that predates this (live `straiker-db-dsn`, no ExternalSecret yet) it first copies the live passwords into Secrets Manager (no rotation), then applies ExternalSecret `straiker-db-passwords` (keys `PASSWORD_<role>`). Chart `straiker-data` reads passwords from it (`passwordsSecret`; empty = legacy in-cluster generation) and still builds `straiker-db-dsn` / `platform-secret`.
- Rotate a role password: change the value in Secrets Manager, force/wait for ESO refresh (1h), re-run `data-bootstrap --rerun-phase` (the job runs ALTER ROLE), then restart the services using it.
- Rollout order: `aws-data --rerun-phase`, `data-bootstrap --rerun-phase`, `verify-data-layer --rerun-phase`.

### Stage 3: platform key + ClickHouse passwords via ESO

- `aws-data` also creates Secrets Manager `<cluster>/platform/keys` (`PLATFORM_INTERNAL_S2S_API_KEY`, 48 chars) and `<cluster>/clickhouse/credentials` (`admin grid_query_ro grid_ingest grid_purge`; list = `CLICKHOUSE_PASSWORD_USERS` in the installer, must match chart `straiker-clickhouse` `users`).
- Generic helper `ensure_synced_secret` (installer): seeds Secrets Manager from the live Secret where values differ (existing installs only, once), applies an ExternalSecret, waits Ready. Used for `straiker-db-passwords`, `platform-keys` (in `data-bootstrap`) and `clickhouse-passwords` (in `clickhouse`).
- Charts read them: `straiker-data` `platform.keysSecret` (S2S key into `platform-secret`), `straiker-clickhouse` `passwordsSecret`. Empty value = legacy in-cluster generation.
- Rollout order on an existing install: `aws-data --rerun-phase`, `clickhouse --rerun-phase`, `data-bootstrap --rerun-phase`, `verify-data-layer --rerun-phase`.
- Still chart-built (from Secrets Manager inputs): `straiker-db-dsn`, `platform-secret`. Not yet in Secrets Manager: `straiker-secrets` (shared keys, bootstrap admin), api-gateway secrets, frontend auth.

### Stage 4: shared keys, session keys, Aurora admin via ESO

- `aws-data` also creates Secrets Manager `<cluster>/platform/shared` (`SHARED_SECRET_PROPS`: INTERNAL_API_KEY, SYS__FOUNDATION_API_KEY, VLLM_API_KEY, SYS__INFERENCE_API_KEY, IRIS_ADMIN_API_KEY, BOOTSTRAP_ADMIN_PASSWORD, BOOTSTRAP_ADMIN_PASSWORD_HASH), `<cluster>/frontend/auth` (SESSION_SIGNING_KEY) and `<cluster>/argus/session` (SYS__ARGUS_SESSION_SECRET_KEY). The ESO role also reads the RDS master secret (`aurora_master_secret`).
- `shared-secrets` (with `--data-layer`): the installer still generates the keys once; they are copied into Secrets Manager and `straiker-secrets` is then kept in sync by ExternalSecret `straiker-secrets-sync` with creationPolicy Merge (keys added by other phases, e.g. provider API keys, are left alone).
- Session keys: charts `straiker-frontend` / `straiker-defend` read `sessionKeySecret` (ESO-synced `frontend-session-source` / `defend-session-source`); empty = legacy generation.
- `straiker-aurora-admin` is an ExternalSecret on the RDS-managed master secret, so it follows RDS's automatic rotation.
- Left out on purpose: api-gateway OAuth/env keys (install-time Helm inputs; Cognito later), `straiker-credential` (customer key).
- **Chart source fix:** `straiker-core`, `straiker-defend` and `straiker-ascend` are now installed from the workspace chart (`chart_ref`; a pinned `--chart-version` still uses the published chart). Before this, a local chart change (e.g. `redis.existingSecret` for Ascend) was silently ignored because the phases used the published repo. `verify-data-layer` now checks that Ascend's `SYS__REDIS_URL` comes from `iris-redis` and that all ExternalSecrets are Ready.
- Rollout order on an existing install: `aws-data`, `shared-secrets`, `data-bootstrap`, `straiker-core,straiker-defend`, `verify-data-layer` (all `--rerun-phase`).
- Remaining: flip `straiker-db-dsn` / `platform-secret` themselves to ExternalSecrets (all sources are now in Secrets Manager).

### Stage 5: `straiker-db-dsn` and `platform-secret` are ExternalSecrets

- Chart `straiker-data` `eso.enabled` (set by `data-bootstrap` for `--data-layer`): `templates/eso-secrets.yaml` renders ExternalSecrets for `straiker-db-dsn` and `platform-secret` (ESO template engine v2) reading Secrets Manager `<cluster>/db/passwords`, `platform/keys`, `platform/api-gateway`, `platform/shared`, `clickhouse/credentials`. Hosts, ports, user names and MSK brokers are literals from chart values (ClickHouse host values come from the live `clickhouse-credentials`). `eso.enabled=false` keeps the chart-built secrets (`dsn-secret.yaml`) for non-ESO installs.
- Takeover is safe: `eso_creation_policy` uses `Merge` for a pre-existing unowned Secret (no delete, no gap), `Owner` otherwise. `eso_preview_diff` first renders the ExternalSecrets against `*-preview` targets and compares every key with the live Secrets; any difference blocks the phase and nothing changes.
- Rotating a value in Secrets Manager updates the Secret within `refreshInterval` (1h) but pods only pick it up on restart.
- Now redundant (left in place for rollback): ExternalSecrets `straiker-db-passwords` and `platform-keys` and the chart's `passwordsSecret` / `platform.keysSecret` modes. Candidates for a later cleanup.
- Result on dl-test: 10 ExternalSecrets, all SecretSynced; preview diff matched every key; verify-data-layer all PASS.

## OpenSearch Service (managed domain)

- `aws-data` creates domain `<cluster>-oss` (`opensearch_domains`, default `main`): OpenSearch 3.7 (AWS offers no 3.6; the bundled pod ran 3.6.0; SaaS runs 2.19), VPC (EKS private subnets, SG allows HTTPS from the client CIDRs), fine-grained access control with internal master user `admin`, encryption at rest (data KMS key) + node-to-node, TLS 1.2. Size by `provision_strategy`: min = 1 × t3.small.search (gp2, no masters); ha/max = 3 data (r7g.large / r7g.xlarge) + 3 × m7g.large masters across up to 3 AZs, multi-AZ with standby when 3 AZs (SaaS Frankfurt shape). The master password is generated by Terraform (in state, like the Redis token) and published to Secrets Manager `<cluster>/opensearch/main` ({username, password, endpoint, url}). The service-linked role is created only if missing (decision remembered in metadata `opensearch_create_slr`).
- Installer: `aws-data` records `opensearch_endpoint` / `opensearch_secret_name`; `straiker-system` (`tags.opensearch=false`, `opensearchExternal.*`) and `straiker-core` (frontend `opensearch.credentialsSecret`) use ExternalSecret `opensearch-credentials`; Benthos writes over TLS with basic auth; `verify-data-layer` checks `_cluster/health` from a pod (the domain is reachable only inside the VPC).
- The SaaS Vercel frontend reaches OpenSearch through a Lambda proxy; the on-prem frontend (`onprem/release`) talks to it directly with OPENSEARCH_URL/USERNAME/PASSWORD.
- Everything uses the master user (SaaS has per-consumer roles via the `opensearch-access` unit) — a later step. No data is migrated from the bundled pod; after the switch delete its PVC by hand (`kubectl -n straiker delete pvc opensearch-cluster-master-opensearch-cluster-master-0`).
- Rollout order: `aws-data` (domain takes ~20-40 min), `straiker-system`, `straiker-core`, `verify-data-layer` (all `--rerun-phase`).
