#!/bin/bash
# One sync cycle: registry Postgres -> grid.<t> (ClickPipes-compatible ReplacingMergeTree
# tables carrying _peerdb_version / _peerdb_is_deleted). Idempotent; safe to re-run.
set -euo pipefail

CH=(clickhouse-client --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" --password "$CH_PASSWORD")
q() { "${CH[@]}" --query "$1"; }

# Monotonic per cycle (microseconds); newer cycle always wins over older rows.
V=$(( $(date +%s) * 1000000 ))

tables="$(q "SELECT table FROM system.columns WHERE database = 'grid' AND name = '_peerdb_is_deleted' ORDER BY table")"
synced=0; skipped=0
for t in $tables; do
  src="postgresql('${PG_HOST}:${PG_PORT}', '${PG_DATABASE}', '${t}', '${PG_USER}', '${PG_PASSWORD}', '${PG_SCHEMA}')"

  # Postgres table not (yet) present in this registry release -> skip, not an error.
  if ! pgcols="$(q "DESCRIBE TABLE ${src}" 2>/dev/null | cut -f1)"; then
    echo "skip ${t}: not in ${PG_DATABASE}.${PG_SCHEMA}"; skipped=$((skipped + 1)); continue
  fi

  # Columns present on both sides (the CH replica may carry defaults PG lacks), minus bookkeeping.
  chcols="$(q "SELECT name FROM system.columns WHERE database = 'grid' AND table = '${t}' AND name NOT LIKE '\\_peerdb\\_%' ORDER BY position")"
  cols=""
  for c in $chcols; do
    if grep -qx "$c" <<<"$pgcols"; then cols="${cols:+$cols, }\`$c\`"; fi
  done
  allcols=""
  for c in $chcols; do allcols="${allcols:+$allcols, }\`$c\`"; done
  [[ -n "$cols" ]] || { echo "skip ${t}: no common columns"; skipped=$((skipped + 1)); continue; }

  q "INSERT INTO grid.\`${t}\` (${cols}, _peerdb_version, _peerdb_is_deleted) SELECT ${cols}, ${V}, 0 FROM ${src}"
  # Rows not refreshed this cycle are gone from Postgres: tombstone them (newer version, deleted).
  q "INSERT INTO grid.\`${t}\` (${allcols}, _peerdb_version, _peerdb_is_deleted) SELECT ${allcols}, ${V}, 1 FROM grid.\`${t}\` FINAL WHERE _peerdb_is_deleted = 0 AND _peerdb_version < ${V}"
  synced=$((synced + 1))

  if [[ "${OPTIMIZE_HOURLY:-false}" == "true" && "$(date +%M)" == "00" ]]; then
    q "OPTIMIZE TABLE grid.\`${t}\` FINAL" || true
  fi
done
echo "sync done: ${synced} tables synced, ${skipped} skipped"
