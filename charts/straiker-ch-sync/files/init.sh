#!/bin/bash
# Creates the grid CDC replica tables (idempotent: CREATE ... IF NOT EXISTS).
set -euo pipefail
sql=/config/cdc_targets.sql
if [[ "${CH_REPLICATED:-false}" == "true" ]]; then
  # Replicated database: a plain MergeTree-family table would stay local to one replica. The engine arguments
  # (e.g. the _peerdb_version column) are kept; the ZooKeeper path/replica are the server defaults.
  sql=/tmp/cdc_targets.replicated.sql
  sed -E 's/ENGINE[[:space:]]*=[[:space:]]*(Replacing|Aggregating|Summing|Collapsing|VersionedCollapsing)?MergeTree/ENGINE = Replicated\1MergeTree/g' /config/cdc_targets.sql > "$sql"
fi
clickhouse-client --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" --password "$CH_PASSWORD" --multiquery < "$sql"
echo "cdc targets ready"
