#!/usr/bin/env bash
# Read-only audit of the in-cluster Postgres, Valkey and OpenSearch of the old (non-data-layer) install mode.
#
# A data-layer install (the only AWS install now) uses Aurora, ElastiCache and the managed OpenSearch domain, so these three should not exist.
# Older installs still have them (left over from an earlier straiker-system revision). For each one this prints whether it exists and whether
# anything uses it: references from other workloads, keys, rows, indices. Nothing is changed (get / exec of SELECT and GET calls only).
#
#   scripts/audit-legacy-incluster.sh [--kubeconfig FILE] [--namespace NS] [--expect-clean]
#
# --expect-clean: exit 1 if any of the three exists (use it after a FRESH install: only straiker-benthos should be there).
set -uo pipefail

NS="straiker"
KCFG=""
EXPECT_CLEAN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KCFG=${2:-}; shift 2 ;;
    --namespace) NS=${2:-}; shift 2 ;;
    --expect-clean) EXPECT_CLEAN=true; shift ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option '$1'" >&2; exit 2 ;;
  esac
done
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 2; }

k() {
  if [[ -n "${KCFG}" ]]; then kubectl --kubeconfig "${KCFG}" -n "${NS}" "$@"; else kubectl -n "${NS}" "$@"; fi
}

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
LEGACY_FOUND=0

say() { printf '%s\n' "$*"; }
verdict() { printf '  %-10s %s\n' "$1" "$2"; }

# Workloads (other than the three themselves) whose environment or arguments name one of them.
k get deploy,sts,cronjob,job -o json >"${TMP}" 2>/dev/null || { echo "Cannot read workloads in namespace '${NS}'." >&2; exit 2; }
refs_to() { # $1 = regex of the service names
  python3 - "${TMP}" "$1" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
pat = re.compile(sys.argv[2], re.I)
own = ("StatefulSet/postgres", "Deployment/valkey", "StatefulSet/opensearch")
hits = []
for it in d["items"]:
    n = it["kind"] + "/" + it["metadata"]["name"]
    if n.startswith(own):
        continue
    spec = it["spec"]["jobTemplate"]["spec"]["template"]["spec"] if it["kind"] == "CronJob" else it["spec"]["template"]["spec"]
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        vals = [str(e.get("value", "")) for e in c.get("env", [])]
        vals += [str(a) for a in (c.get("args") or []) + (c.get("command") or [])]
        # a mirror/sync Job names images such as valkey/valkey: not a connection
        if any(pat.search(v) for v in vals) and not n.startswith(("Job/straiker-artifact", "CronJob/straiker-artifact")):
            hits.append(n)
            break
print(" ".join(sorted(set(hits))))
PY
}

say "Namespace: ${NS}"
say

# ---------------------------------------------------------------- Valkey
say "Valkey (in-cluster cache; replaced by ElastiCache)"
if k get deploy valkey >/dev/null 2>&1; then
  LEGACY_FOUND=1
  r="$(refs_to '(^|[^a-z/])valkey(\.|:|-service|$)|valkey\.'"${NS}")"
  keys="$(k exec deploy/valkey -- valkey-cli dbsize 2>/dev/null | tr -d '[:space:]')"
  conns="$(k exec deploy/valkey -- valkey-cli info stats 2>/dev/null | sed -n 's/^total_connections_received:\([0-9]*\).*/\1/p' | tr -d '\r')"
  cmds="$(k exec deploy/valkey -- valkey-cli info stats 2>/dev/null | sed -n 's/^total_commands_processed:\([0-9]*\).*/\1/p' | tr -d '\r')"
  verdict "exists" "Deployment/valkey"
  verdict "refs" "${r:-none}"
  verdict "data" "keys=${keys:-?}  connections=${conns:-?}  commands=${cmds:-?} (commands about equal to connections = its own health probe)"
  if [[ -z "${r}" && "${keys:-1}" == "0" ]]; then verdict "UNUSED" "nothing references it and it holds no keys"; else verdict "IN USE?" "check the references and keys above"; fi
else
  verdict "ABSENT" "no Deployment/valkey"
fi
say

# ---------------------------------------------------------------- Postgres
say "Postgres (in-cluster database; replaced by Aurora)"
if k get sts postgres >/dev/null 2>&1; then
  LEGACY_FOUND=1
  r="$(refs_to '(^|[^a-z/])postgres(\.|:)|postgres\.'"${NS}")"
  user="$(k get sts postgres -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_USER")].value}' 2>/dev/null)"
  verdict "exists" "StatefulSet/postgres (superuser '${user:-?}')"
  verdict "refs" "${r:-none}"
  if [[ -n "${user}" ]]; then
    dbs="$(k exec postgres-0 -- psql -U "${user}" -d postgres -tA -c "select datname from pg_database where not datistemplate" 2>/dev/null)"
    total_rows=0
    for db in ${dbs}; do
      n="$(k exec postgres-0 -- psql -U "${user}" -d "${db}" -tA -c "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables" 2>/dev/null | tr -d '[:space:]')"
      verdict "database" "${db}: ${n:-?} rows in user tables"
      total_rows=$((total_rows + ${n:-0}))
    done
    writes="$(k exec postgres-0 -- psql -U "${user}" -d postgres -tA -c "select coalesce(sum(tup_inserted + tup_updated),0) from pg_stat_database where datname not like 'template%'" 2>/dev/null | tr -d '[:space:]')"
    verdict "data" "rows=${total_rows}  tuples inserted or updated since start=${writes:-?}"
    if [[ -z "${r}" && "${total_rows}" == "0" && "${writes:-1}" == "0" ]]; then verdict "UNUSED" "nothing references it and nothing was ever written"; else verdict "IN USE?" "check the references and rows above"; fi
  else
    verdict "IN USE?" "could not read the superuser name; check by hand"
  fi
else
  verdict "ABSENT" "no StatefulSet/postgres"
fi
say

# ---------------------------------------------------------------- OpenSearch
say "OpenSearch (bundled pod; replaced by the managed domain when the data tier created one)"
if k get sts opensearch-cluster-master >/dev/null 2>&1; then
  LEGACY_FOUND=1
  r="$(refs_to 'opensearch-cluster-master')"
  verdict "exists" "StatefulSet/opensearch-cluster-master"
  verdict "refs" "${r:-none}"
  idx="$(k exec opensearch-cluster-master-0 -c opensearch -- curl -s -m 8 'http://localhost:9200/_cat/indices?h=index,docs.count' 2>/dev/null)"
  app_docs="$(printf '%s\n' "${idx}" | awk '$1 !~ /^\./ && $1 !~ /^top_queries/ {s += $2} END {print s + 0}')"
  app_idx="$(printf '%s\n' "${idx}" | awk '$1 !~ /^\./ && $1 !~ /^top_queries/ && NF {print $1}' | tr '\n' ' ')"
  verdict "data" "application indices: ${app_idx:-none}  (documents: ${app_docs})"
  if [[ -z "${r}" && "${app_docs}" == "0" ]]; then verdict "UNUSED" "no application index (only OpenSearch's own housekeeping)"; else verdict "IN USE?" "check the references and indices above"; fi
else
  verdict "ABSENT" "no StatefulSet/opensearch-cluster-master"
fi
say

# ---------------------------------------------------------------- Benthos (kept) and where it writes
say "Benthos (kept: Ascend's archive pipeline) and where it writes"
if k get cm straiker-benthos-pipeline >/dev/null 2>&1; then
  target="$(k get cm straiker-benthos-pipeline -o jsonpath='{.data.archive-pipeline\.yaml}' 2>/dev/null | grep -o 'https\?://[^ "]*' | head -1)"
  verdict "target" "${target:-?}"
  if [[ "${target}" == *opensearch-cluster-master* ]]; then
    verdict "NOTE" "archives go to the IN-CLUSTER OpenSearch; the console reads the managed domain on a data-layer install, so re-run: --phase straiker-system --rerun-phase"
  else
    verdict "OK" "archives go to the managed OpenSearch domain"
  fi
else
  verdict "ABSENT" "no straiker-benthos-pipeline ConfigMap"
fi
say

if [[ "${EXPECT_CLEAN}" == true && "${LEGACY_FOUND}" -ne 0 ]]; then
  say "FAIL: expected none of Valkey, Postgres, bundled OpenSearch on this install, but at least one exists."
  exit 1
fi
[[ "${EXPECT_CLEAN}" == true ]] && say "PASS: none of Valkey, Postgres or the bundled OpenSearch exists."
exit 0
