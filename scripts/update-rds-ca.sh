#!/usr/bin/env bash
# Refresh the RDS CA bundle the frontend and ClickHouse (ch-sync) charts trust for Aurora (verified TLS, no NODE_TLS_REJECT_UNAUTHORIZED=0).
# Source: AWS's official trust store. Run from anywhere, review the diff, commit. AWS rotates this rarely.
set -euo pipefail
URL="https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTS=("${ROOT}/charts/straiker-core/charts/straiker-frontend/files/rds-global-bundle.pem" "${ROOT}/charts/straiker-clickhouse/files/rds-global-bundle.pem")
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
curl -fsSL --max-time 60 -o "${tmp}" "${URL}"
count="$(grep -c 'BEGIN CERTIFICATE' "${tmp}")"
if [[ "${count}" -lt 50 ]] || grep -qv -e '^-----' -e '^[A-Za-z0-9+/=]*$' "${tmp}"; then
  echo "Unexpected bundle contents (${count} certificates); not replacing the bundles" >&2
  exit 1
fi
for DEST in "${DESTS[@]}"; do
  cp "${tmp}" "${DEST}"
  echo "Updated ${DEST}: ${count} certificates, sha256 $(shasum -a 256 "${DEST}" | cut -d' ' -f1)"
done
