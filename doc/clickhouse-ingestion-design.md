# ClickHouse ingestion for on-prem (replacing ClickPipes)

Status: Part B (Postgres dims) and Part A (Kafka -> ClickHouse) BUILT and tested locally in Docker; nothing run on AWS yet. SaaS fills ClickHouse Cloud with two ClickPipes mechanisms; on-prem
runs ClickHouse as a pod (`charts/straiker-clickhouse`) and needs a replacement for each.

## What has to be replaced

| # | SaaS (ClickPipes) | Source | Target in `grid` | Notes |
|---|---|---|---|---|
| 1 | Kafka pipe | `s6r.events` | `raw_event` | JSON, explicit mapping; **map `revision`** (RMT version column) |
| 2 | Kafka pipe | `s6r.findings` | `raw_finding` | **do not map `ingested_at`** (MATERIALIZED); `span` object -> String column |
| 3 | Kafka pipe | `platform.audit` | `audit_event` | CloudEvents; read `$.data.*`, flatten actor/target/context/outcome; `refs`/`change` -> JSON String; do not map `ingested_at` |
| 4 | Postgres CDC pipe | registry DB, 12 tables: `resource`, `resource_agent`, `resource_identity`, `resource_model`, `resource_mcp_server`, `resource_tool`, `resource_skill`, `resource_alias`, `resource_tag`, `resource_tag_map`, `resource_action_state`, `finding_check` (+ `resource_source`) | same names | ReplacingMergeTree(`_peerdb_version`) + `_peerdb_is_deleted`; readers use `FINAL WHERE _peerdb_is_deleted = 0` (`grid.v_dict_*`); ~60 s lag today |

Constraint: MSK Serverless is IAM-only and ClickHouse's Kafka engine cannot do MSK IAM, so Kafka -> ClickHouse needs a bridge.

## Part A: Kafka -> ClickHouse (pipes 1-3)

**Recommended: Redpanda Connect pod(s)**, one stream per topic.
- Input `kafka_franz`, SASL `AWS_MSK_IAM`, Pod Identity role (same pattern databridge's Benthos already uses; `redpandadata/connect` is already in the image mirror).
- Processor (bloblang) builds the exact landing row; the field rules above live here. `span`/`refs`/`change` use `format_json()`.
- Output `http_client` to ClickHouse HTTP: `INSERT INTO grid.<t> FORMAT JSONEachRow`, batched (e.g. 5k rows / 1 s), `input_format_skip_unknown_fields=1`, user `admin`-scoped insert user (add `grid_ingest` to the chart).
- Failures: reject to the existing `<topic>.dlq` topics; at-least-once is fine (RMT + producer idempotency dedupe).
- Consumer groups: `grid-ingest-<topic>`; the Pod Identity role needs ReadData/AlterGroup (already allowed by `pod_identity.tf`).
- New chart `charts/straiker-ingest` (3 streams as ConfigMap + Deployment, 1 replica each, KEDA/HPA later).

Rejected: ClickHouse Kafka engine (no IAM), a custom consumer (more code to own).

## Part B: Postgres -> ClickHouse dims (pipe 4)

| Option | Fidelity | Cost | Verdict |
|---|---|---|---|
| **B1: poll with ClickHouse `postgresql()` table function** (CronJob, every ~30-60 s) | Same tables/columns, we stamp `_peerdb_version`/`_peerdb_is_deleted` ourselves | Tiny: no new service, no replication slot/WAL risk; full re-copy per cycle (dims are small) | **Recommended for the demo/first milestone** |
| B2: PeerDB OSS (engine behind ClickPipes PG) | Exact | Heavy: Temporal + catalog DB + several pods, logical replication on Aurora | Later, if estates are large |
| B3: Redpanda Connect `postgres_cdc` | Needs own mapping | Likely enterprise-licensed (verify) | Only if licence is fine |

B1 mechanics (CronJob running `clickhouse-client`, one script, idempotent):
1. **Init (once, before grid migrations):** for each table `CREATE TABLE IF NOT EXISTS grid.<t> ... ENGINE = ReplacingMergeTree(_peerdb_version) ORDER BY (straiker_id, id)` with columns inferred from Postgres (`postgresql()` schema inference) plus `_peerdb_version UInt64`, `_peerdb_is_deleted UInt8`. This satisfies grid migration `00001`'s prerequisite (CDC replicas must exist; dict views resolve columns at create time).
2. **Each cycle:** `INSERT INTO grid.<t> SELECT *, toUnixTimestamp64Milli(now64()), 0 FROM postgresql(<aurora>, 'registry', '<t>', 'ro_user', ...)`.
3. **Deletes:** insert tombstones (`_peerdb_is_deleted = 1`, newer version) for keys present in ClickHouse (FINAL, not deleted) but absent in Postgres.
4. Housekeeping: `OPTIMIZE ... FINAL` off-peak or TTL on old versions to bound growth.
- Postgres side: a read-only role `grid_cdc` on the `registry` DB (add to the `straiker-data` bootstrap Job; password in `straiker-db-dsn`). No `rds.logical_replication` needed.
- Lag ~ cycle length (matches today's ~60 s). If an estate grows beyond what a full copy tolerates, add `updated_at` incremental pulls per table, then move to B2.

## Part A as built

`charts/straiker-ingest` (installer phase `ingest`, after `platform-services`; blocks until grid's migration has created `grid.raw_event`): one Redpanda Connect Deployment in streams mode, three streams (`files/{events,findings,audit}.yaml`, Helm-templated for the MSK IAM block).
- Input `kafka_franz` (TLS + `AWS_MSK_IAM`, Pod Identity role `grid-ingest`), groups `grid-ingest-<topic>`; output = batched NDJSON `INSERT ... FORMAT JSONEachRow` over ClickHouse HTTP as user `grid_ingest` (INSERT on `grid.*` only).
- Mappings: events pass through (maps `revision`; metadata coerced to strings); findings drop `ingested_at`, `span` object -> JSON string; audit reads the CloudEvents `data` (or a bare record) and flattens actor/target/context/outcome, `refs`/`change` -> JSON strings.
- Failures: mapping errors -> `<topic>.dlq`; ClickHouse insert failure after 3 retries -> `<topic>.dlq`. Added topic `platform.audit.dlq`.
- Tested in Docker (Redpanda, ClickHouse 25.8, Redpanda Connect 4.101.0, tables from grid migration 00001, payloads from grid's contract examples): all three tables populate, unparseable message and ClickHouse outage land in the DLQ, numeric metadata/compliance values are coerced. Not tested: MSK IAM auth (Pod Identity, `aws.region`), `seed_brokers` with several brokers via `${BROKERS}`, throughput, and the real Defend/Argus producers.
- Caveats: one replica per stream (add replicas/KEDA later); consumer start is `start_from_oldest`; at-least-once (dedupe via ReplacingMergeTree).

## Part B as built

`charts/straiker-ch-sync` (installer phase `ch-sync`, after `data-bootstrap`, before `platform-services`):
- `files/cdc_targets.sql`: 30 `grid.*` ReplacingMergeTree replica tables, generated by `scripts/sync-platform-charts.sh` from grid's harness fixture (`cdc_snapshot.sql`; note its types are the harness's simplification of what ClickPipes produces).
- Init Job (hook): create tables + first sync. CronJob (every minute, `Forbid`): `files/sync.sh` per table: `INSERT ... SELECT FROM postgresql(...)` (columns = intersection of replica and Postgres), version = cycle time in microseconds; rows not refreshed that cycle get a tombstone (version newer, `_peerdb_is_deleted = 1`); hourly `OPTIMIZE ... FINAL`. Tables absent from Postgres (registry not installed yet / older release) are skipped.
- `grid_cdc`: read-only Postgres role on `registry` (SELECT on existing + future tables of owner `registry`), created by chart `straiker-data`.
- Grid overlay now has `migrations.enabled: true` (DDL creds from `GRID_CH_MIGRATE_*`); `grid-migrations` image added to the mirror.
- Tested in Docker (Postgres 16, ClickHouse 25.8): insert, update, delete (tombstone), re-add, JSONB -> String, repeat runs, skip of missing tables; `grid_cdc` read-only and covers tables created later. Not tested: Aurora SSL path, real registry schema, grid migrations.
- Caveats: the PG password is in the `postgresql()` call text (visible in ClickHouse `query_log`); the sync uses the ClickHouse `admin` user; full copy per cycle (move to incremental/PeerDB for large estates).

## Order of operations in the installer

1. `aws-data`, `clickhouse`, `data-bootstrap` (adds `grid_cdc` PG role + `grid_ingest` CH user).
2. `platform-services`: **registry first** (its Liquibase creates the Postgres tables).
3. New phase `ch-ingest`: run B1 init (creates CDC target tables) -> then grid install with `migrations.enabled=true` (needs `GRID_CH_MIGRATE_*`, already in `platform-secret`) -> start the B1 CronJob and the Part A streams.
4. Grid/registry start reading real data.

## Build estimate (1 engineer)
- Part A (chart + 3 bloblang mappings from `contracts/grid-topics` and `platform.audit` schema, test against a local ClickHouse): 1.5-2 days.
- Part B1 (init DDL generation, sync script, CronJob, tombstones, test): 1-1.5 days.
- Installer wiring + runbook: 0.5 day.

## Open questions / risks
- Exact landing column lists: derive from `deploy/ch-goose/00001_initial.sql` when building the mappings (not yet transcribed).
- `postgresql()` against Aurora needs SSL (`sslmode=require`) options; verify on ClickHouse 25.8.
- Registry `agent purge` uses `grid_purge` grants unchecked against a pod ClickHouse.
- Kafka-sourced rows depend on Defend/Argus producers writing to MSK, which is part of the Defend chart, not this work.
