#!/usr/bin/env bash
# Proves the Kafka -> ClickHouse path end to end: Argus v3 -> MSK (s6r.events, s6r.findings) -> straiker-ingest (Redpanda
# Connect) -> grid.raw_event / grid.raw_finding. platform.audit -> grid.audit_event is reported too.
#
#   scripts/verify-clickhouse-ingest.sh [--namespace straiker] [--wait 90] [--traffic 5] [--expect-audit]
#
# Without DETECT_API_KEY it only OBSERVES for --wait seconds (use it while other traffic runs). With
# DETECT_API_KEY=sk_agt_... it first sends --traffic detect calls through the api-gateway (/api/v3/detect), which is what
# makes Argus v3 emit events and findings. It reads ClickHouse as the read-only user grid_query_ro.
#
# What it reports:
#   1. ingest pod ready, and per stream: messages read, rows written, write errors, messages sent to the dead-letter topic
#      (from Redpanda Connect's own metrics, so a failure shows up even before any row lands)
#   2. row counts of raw_event / raw_finding / audit_event before and after
# Exit 0 = rows landed in raw_event or raw_finding and nothing went to a dead-letter topic or errored; 1 otherwise.
# audit_event needs console activity (create or edit something in the console): it only fails the run with --expect-audit.
set -uo pipefail

NAMESPACE="straiker"
WAIT=90
TRAFFIC=5
EXPECT_AUDIT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --wait) WAIT="${2:-}"; shift 2 ;;
    --traffic) TRAFFIC="${2:-}"; shift 2 ;;
    --expect-audit) EXPECT_AUDIT=true; shift ;;
    -h | --help) sed -n 2,19p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
for cmd in kubectl curl python3; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "ERROR: ${cmd} is required." >&2; exit 2; }
done

PIDS=()
TMP="$(mktemp -d)"
cleanup() { for p in "${PIDS[@]+"${PIDS[@]}"}"; do kill "${p}" 2>/dev/null; done; rm -rf "${TMP}"; }
trap cleanup EXIT

kc() { kubectl -n "${NAMESPACE}" "$@"; }

CH_USER="grid_query_ro"
CH_PASS="$(kc get secret clickhouse-credentials -o jsonpath="{.data.${CH_USER}_password}" 2>/dev/null | base64 -d 2>/dev/null)"
[[ -n "${CH_PASS}" ]] || { echo "ERROR: cannot read ${CH_USER}'s password from secret clickhouse-credentials." >&2; exit 2; }

# counts: prints "table count" lines
counts() {
  kc exec clickhouse-0 -c clickhouse -- env "CLICKHOUSE_USER=${CH_USER}" "CLICKHOUSE_PASSWORD=${CH_PASS}" clickhouse-client --query \
    "SELECT 'raw_event', count() FROM grid.raw_event UNION ALL SELECT 'raw_finding', count() FROM grid.raw_finding UNION ALL SELECT 'audit_event', count() FROM grid.audit_event FORMAT TSV" 2>/dev/null
}
val() { awk -v t="$2" '$1 == t { print $2 }' <<<"$1"; }

# metrics: one line per stream "stream received written errors dlq" from Redpanda Connect's /metrics
metrics() {
  curl -s --max-time 5 http://127.0.0.1:14195/metrics 2>/dev/null | python3 -c '
import re, sys
rows = {}
for line in sys.stdin:
    m = re.match(r"^(input_received|output_sent|output_error)\{(.*)\}\s+([0-9.eE+-]+)", line)
    if not m:
        continue
    name, labels, v = m.group(1), m.group(2), float(m.group(3))
    s = re.search(r"stream=\"([^\"]+)\"", labels)
    if not s:
        continue
    r = rows.setdefault(s.group(1), {"in": 0, "out": 0, "err": 0, "dlq": 0})
    dlq = "cases.0" in labels  # switch case 0 = the dead-letter output
    if name == "input_received": r["in"] += v
    elif name == "output_error": r["err"] += v
    elif name == "output_sent":
        if dlq: r["dlq"] += v
        else: r["out"] += v
for s in ("events", "findings", "audit"):
    r = rows.get(s, {"in": 0, "out": 0, "err": 0, "dlq": 0})
    print(s, int(r["in"]), int(r["out"]), int(r["err"]), int(r["dlq"]))
'
}

echo "ClickHouse ingest verification (namespace ${NAMESPACE})"
echo "1. ingest pod"
ready="$(kc get deploy straiker-ingest -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
if [[ "${ready:-0}" -ge 1 ]]; then echo "  PASS  straiker-ingest ready (${ready})"; else echo "  FAIL  straiker-ingest is not ready"; exit 1; fi

# kubectl directly (not through kc): $! must be the kubectl process, or cleanup would leave the port-forward running
kubectl -n "${NAMESPACE}" port-forward deploy/straiker-ingest 14195:4195 >/dev/null 2>&1 &
PIDS+=($!)
for _ in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null --max-time 2 http://127.0.0.1:14195/ping && break; sleep 1; done

before_c="$(counts)"; before_m="$(metrics)"
[[ -n "${before_c}" ]] || { echo "ERROR: could not query ClickHouse (kubectl exec into clickhouse-0)." >&2; exit 2; }

if [[ -n "${DETECT_API_KEY:-}" && "${TRAFFIC}" -gt 0 ]]; then
  echo "2. traffic: ${TRAFFIC} detect calls through the api-gateway"
  kubectl -n "${NAMESPACE}" port-forward svc/api-gateway 18080:443 >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null --max-time 2 http://127.0.0.1:18080/ && break; sleep 1; done
  ok=0
  for i in $(seq 1 "${TRAFFIC}"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 -X POST http://127.0.0.1:18080/api/v3/detect \
      -H "Authorization: Bearer ${DETECT_API_KEY}" -H 'Content-Type: application/json' \
      -d "{\"user_name\":\"ingest-check\",\"prompt\":\"Ingest check ${i}: what is the capital of France?\"}")"
    [[ "${code}" == 200 ]] && ok=$((ok + 1))
  done
  echo "  ${ok}/${TRAFFIC} calls answered 200"
  [[ ${ok} -eq 0 ]] && echo "  WARN  no call succeeded: check the key and that /api/v3/detect is reachable (scripts/smoke-test-detect.sh)"
else
  echo "2. traffic: none sent (set DETECT_API_KEY to send some); observing for ${WAIT}s"
fi

echo "3. waiting up to ${WAIT}s for rows"
after_c="${before_c}"
deadline=$((SECONDS + WAIT))
while [[ ${SECONDS} -lt ${deadline} ]]; do
  after_c="$(counts)"
  if [[ "$(val "${after_c}" raw_event)" -gt "$(val "${before_c}" raw_event)" && "$(val "${after_c}" raw_finding)" -gt "$(val "${before_c}" raw_finding)" ]]; then break; fi
  sleep 5
done
after_m="$(metrics)"

echo "4. result"
printf '  %-12s %10s %10s\n' table before after
for t in raw_event raw_finding audit_event; do printf '  %-12s %10s %10s\n' "${t}" "$(val "${before_c}" "${t}")" "$(val "${after_c}" "${t}")"; done
echo "  ingest streams (since the pod started): read / written / errors / dead-lettered"
bad=false
while read -r s i o e d; do
  printf '  %-9s %8s %8s %6s %6s\n' "${s}" "${i}" "${o}" "${e}" "${d}"
  [[ "${e}" -gt 0 || "${d}" -gt 0 ]] && bad=true
done <<<"${after_m}"

fail=false
re_new=$(( $(val "${after_c}" raw_event) - $(val "${before_c}" raw_event) ))
rf_new=$(( $(val "${after_c}" raw_finding) - $(val "${before_c}" raw_finding) ))
au_new=$(( $(val "${after_c}" audit_event) - $(val "${before_c}" audit_event) ))
echo
if [[ ${re_new} -gt 0 || ${rf_new} -gt 0 ]]; then
  echo "  PASS  rows landed (raw_event +${re_new}, raw_finding +${rf_new})"
else
  echo "  FAIL  no new rows in raw_event or raw_finding"
  echo "        no traffic reached Argus v3? read the 'read' column: 0 = nothing arrived on the topic (Argus did not publish);"
  echo "        read > 0 and written 0 = the ClickHouse insert fails (see: kubectl logs deploy/straiker-ingest)"
  fail=true
fi
if [[ "${bad}" == true ]]; then echo "  FAIL  a stream has write errors or dead-lettered messages (kubectl logs deploy/straiker-ingest; <topic>.dlq holds them)"; fail=true; fi
if [[ ${au_new} -gt 0 ]]; then echo "  PASS  audit_event +${au_new}"
elif [[ "${EXPECT_AUDIT}" == true ]]; then echo "  FAIL  no new audit_event rows (do something in the console, then re-run)"; fail=true
else echo "  INFO  no new audit_event rows (needs console activity; use --expect-audit to require it)"; fi
[[ "${fail}" == false ]]
