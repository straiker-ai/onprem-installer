#!/usr/bin/env bash
# One command for the whole AWS "data layer" install: EKS + Karpenter, ECR + image/model sync, Aurora, MSK,
# ElastiCache, EFS, ClickHouse (2 replicas + Keeper), the platform services, Ascend and Defend, and the edge.
#
#   scripts/install-data-layer.sh --cluster-name dl-test --region us-east-2 \
#       --customer-name acme --profile my-aws-profile [--customer-key-file ./key.txt]
#
# It runs scripts/install-straiker.sh (all phases, in order) and re-runs it while a phase is only waiting on
# something running in the cluster (image/model sync Jobs, node launches). It stops, printing the installer's own
# message, when a phase is blocked on something a person has to fix. Phase state lives in ~/.straiker/install.json,
# so re-running this command (or Ctrl-C and re-running) resumes where it stopped; finished phases are skipped.
#
# Interactive on the first run only: the Straiker customer key (unless --customer-key-file is given) and, in
# bedrock mode, the Bedrock region/inference profile. Both are stored in the install state afterwards.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${STRAIKER_INSTALLER:-${REPO_ROOT}/scripts/install-straiker.sh}"
STATE_FILE="${STRAIKER_STATE_FILE:-${HOME}/.straiker/install.json}"

CLUSTER_NAME=""
REGION=""
PROFILE="${AWS_PROFILE:-}"
CUSTOMER_NAME=""
CUSTOMER_KEY_FILE=""
NAMESPACE="straiker"
PROVISION_STRATEGY="min"
EDGE_TYPE="internal"
PRODUCTS="ascend,defend"
AI_PROVIDER_MODE="bedrock"
EXPECT_ACCOUNT=""
TIMEOUT_MINUTES=240
POLL_SECONDS=30
ASSUME_YES=false
CHECK_ONLY=false
STATUS_ONLY=false
EXTRA_ARGS=()
MULTIARCH_SET=false
MULTIARCH_LIST=()

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Required:
  --cluster-name NAME        EKS cluster name (created by the installer)
  --region REGION            AWS region; everything is created in this region only
  --customer-name NAME       Straiker customer name (the <name> of <name>@straiker.ai)

Options:
  --profile PROFILE          AWS profile (default: $AWS_PROFILE)
  --customer-key-file FILE   file holding the Straiker customer key (first run only). Without it the installer
                             prompts for the key once.
  --expect-account ID        stop unless the AWS account is ID (guards against the wrong profile)
  --namespace NS             Kubernetes namespace (default: straiker)
  --provision-strategy S     min | ha | max (default: min)
  --edge-type T              internal | none | tailscale | alb (default: internal = Caddy, self-signed)
  --products LIST            default: ascend,defend
  --ai-provider-mode M       own-keys | bedrock | trial-key (default: bedrock)
  --multiarch-override R=U   image whose copy in your ECR lacks arm64, as <repo>:<tag>=<upstream> (repeatable).
                             Default: maximhq/bifrost at the tag pinned in charts/straiker-artifact, from Docker Hub.
                             Pass --multiarch-override none to disable.
  --installer-arg ARG        extra argument for install-straiker.sh (repeatable)
  --timeout-minutes N        give up waiting after N minutes in total (default: 240)
  --poll-seconds N           seconds between checks while waiting (default: 30)
  --yes                      do not ask for confirmation before creating resources
  --check                    run the pre-flight checks only
  --status                   print the phase status and exit
  -h, --help
EOF
}

log() { printf '[install-data-layer] %s\n' "$*"; }
die() { printf '[install-data-layer] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --customer-name) CUSTOMER_NAME="${2:-}"; shift 2 ;;
    --customer-key-file) CUSTOMER_KEY_FILE="${2:-}"; shift 2 ;;
    --expect-account) EXPECT_ACCOUNT="${2:-}"; shift 2 ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --provision-strategy) PROVISION_STRATEGY="${2:-}"; shift 2 ;;
    --edge-type) EDGE_TYPE="${2:-}"; shift 2 ;;
    --products) PRODUCTS="${2:-}"; shift 2 ;;
    --ai-provider-mode) AI_PROVIDER_MODE="${2:-}"; shift 2 ;;
    --multiarch-override) MULTIARCH_SET=true; [[ "${2:-}" == "none" ]] || MULTIARCH_LIST+=("${2:-}"); shift 2 ;;
    --installer-arg) EXTRA_ARGS+=("${2:-}"); shift 2 ;;
    --timeout-minutes) TIMEOUT_MINUTES="${2:-}"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --status) STATUS_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -x "${INSTALLER}" ]] || die "installer not found or not executable: ${INSTALLER}"

installer_base_args() {
  local a=(--aws-region "${REGION}" --cluster-name "${CLUSTER_NAME}" --namespace "${NAMESPACE}")
  [[ -n "${PROFILE}" ]] && a+=(--aws-profile "${PROFILE}")
  printf '%s\n' "${a[@]}"
}

if [[ "${STATUS_ONLY}" == true ]]; then
  [[ -n "${REGION}" && -n "${CLUSTER_NAME}" ]] || die "--status needs --region and --cluster-name"
  args=()
  while IFS= read -r l; do args+=("$l"); done < <(installer_base_args)
  exec "${INSTALLER}" "${args[@]}" --status
fi

[[ -n "${CLUSTER_NAME}" ]] || die "--cluster-name is required (see --help)"
[[ -n "${REGION}" ]] || die "--region is required"
[[ -n "${CUSTOMER_NAME}" ]] || die "--customer-name is required"
[[ "${PROVISION_STRATEGY}" =~ ^(min|ha|max)$ ]] || die "--provision-strategy must be min, ha or max"
[[ "${TIMEOUT_MINUTES}" =~ ^[0-9]+$ && "${POLL_SECONDS}" =~ ^[0-9]+$ ]] || die "--timeout-minutes and --poll-seconds must be numbers"
if [[ -n "${CUSTOMER_KEY_FILE}" && ! -r "${CUSTOMER_KEY_FILE}" ]]; then die "cannot read --customer-key-file ${CUSTOMER_KEY_FILE}"; fi

# Default multi-arch fix: the bifrost image the Straiker mirror carries is amd64-only, but the shared node pool is
# arm64, so bifrost dies with "exec format error". Copy the multi-arch upstream into this account's ECR.
if [[ "${MULTIARCH_SET}" != true ]]; then
  bifrost_tag="$(awk '/onprem-base\/maximhq\/bifrost/{f=1;next} f&&/tag:/{print $2; exit}' "${REPO_ROOT}/charts/straiker-artifact/values.yaml" 2>/dev/null || true)"
  [[ -n "${bifrost_tag}" ]] && MULTIARCH_LIST+=("maximhq/bifrost:${bifrost_tag}=docker.io/maximhq/bifrost:${bifrost_tag}")
fi
MULTIARCH_OVERRIDES=""
if [[ ${#MULTIARCH_LIST[@]} -gt 0 ]]; then MULTIARCH_OVERRIDES="${MULTIARCH_LIST[*]}"; fi
export MULTIARCH_OVERRIDES

# ------------------------------------------------------------------ pre-flight
preflight() {
  local missing=() t
  for t in aws kubectl helm python3 curl; do command -v "${t}" >/dev/null 2>&1 || missing+=("${t}"); done
  if [[ -n "${MULTIARCH_OVERRIDES}" ]] && ! command -v crane >/dev/null 2>&1; then missing+=("crane (brew install crane)"); fi
  [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]}"

  [[ -n "${PROFILE}" ]] && export AWS_PROFILE="${PROFILE}"
  export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"

  local ident
  if ! ident="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1)"; then
    printf '%s\n' "${ident}" >&2
    die "AWS credentials are not usable. For SSO: aws sso login --profile ${PROFILE:-<profile>}"
  fi
  ACCOUNT_ID="$(printf '%s' "${ident}" | awk '{print $1}')"
  log "AWS account ${ACCOUNT_ID}, region ${REGION}, profile ${PROFILE:-<default>}"
  if [[ -n "${EXPECT_ACCOUNT}" && "${ACCOUNT_ID}" != "${EXPECT_ACCOUNT}" ]]; then
    die "AWS account is ${ACCOUNT_ID} but --expect-account is ${EXPECT_ACCOUNT}; refusing to continue."
  fi
}

# ------------------------------------------------------------------ state
# prints: <install.status>|<install.message>
state_summary() {
  python3 - "${STATE_FILE}" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))["install"]
except Exception:
    print("none|")
    sys.exit(0)
print("%s|%s" % (d.get("status", "none"), (d.get("message") or "").replace("\n", " ")))
PY
}

# Is the recorded state for this cluster? (a stale state file from another cluster must not be resumed blindly)
state_cluster() {
  python3 - "${STATE_FILE}" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["install"]["metadata"].get("cluster_name", ""))
except Exception:
    print("")
PY
}

# A blocked state that only means "wait": something is running in the cluster and will finish by itself.
is_waiting_message() {
  case "$1" in
    *"still running in-cluster"*|*"survives this command exiting"*) return 0 ;;
    *) return 1 ;;
  esac
}

report_plan() {
  cat <<EOF

About to install into AWS account ${ACCOUNT_ID}, region ${REGION}:
  cluster ........ ${CLUSTER_NAME} (namespace ${NAMESPACE}), strategy ${PROVISION_STRATEGY}
  customer ....... ${CUSTOMER_NAME}, products ${PRODUCTS}, AI provider ${AI_PROVIDER_MODE}, edge ${EDGE_TYPE}
  creates ........ VPC + EKS + Karpenter, ECR, Aurora PostgreSQL, MSK, ElastiCache, EFS, ClickHouse (2 + Keeper),
                   the platform services, Ascend and Defend, and GPU nodes for the inference models
  time / cost .... about 1.5-2 hours, and roughly 6-8 USD per hour while it runs (GPU nodes dominate)
EOF
}

# ------------------------------------------------------------------ main
preflight
if [[ "${CHECK_ONLY}" == true ]]; then
  log "pre-flight OK"
  exit 0
fi

prev_cluster="$(state_cluster)"
if [[ -n "${prev_cluster}" && "${prev_cluster}" != "${CLUSTER_NAME}" ]]; then
  die "${STATE_FILE} belongs to cluster '${prev_cluster}', not '${CLUSTER_NAME}'. Move it aside (it holds that install's phase state) and re-run."
fi

if [[ "${ASSUME_YES}" != true ]]; then
  report_plan
  printf '\nContinue? [y/N] '
  read -r answer < /dev/tty || answer=""
  [[ "${answer}" =~ ^[Yy]$ ]] || die "aborted"
fi

base_args=()
while IFS= read -r l; do base_args+=("$l"); done < <(installer_base_args)
run_args=("${base_args[@]}" --install-eks --data-layer --provision-strategy "${PROVISION_STRATEGY}"
  --straiker-customer-name "${CUSTOMER_NAME}" --products "${PRODUCTS}" --ai-provider-mode "${AI_PROVIDER_MODE}"
  --edge-type "${EDGE_TYPE}" --yes)
command -v tofu >/dev/null 2>&1 || run_args+=(--install-tofu)
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then run_args+=("${EXTRA_ARGS[@]}"); fi

# The customer key is stored in the install state after the first pass, so only the first run needs it.
first_run_key_args=()
if [[ -n "${CUSTOMER_KEY_FILE}" ]]; then
  first_run_key_args=(--straiker-customer-key "$(tr -d '[:space:]' < "${CUSTOMER_KEY_FILE}")")
fi

start_epoch="$(date +%s)"
deadline=$(( start_epoch + TIMEOUT_MINUTES * 60 ))
pass=0
while true; do
  pass=$(( pass + 1 ))
  log "installer pass ${pass}"
  if [[ ${pass} -eq 1 && ${#first_run_key_args[@]} -gt 0 ]]; then
    "${INSTALLER}" "${run_args[@]}" "${first_run_key_args[@]}" || die "installer exited with an error (see above). Fix it and re-run this command to resume."
  else
    "${INSTALLER}" "${run_args[@]}" || die "installer exited with an error (see above). Fix it and re-run this command to resume."
  fi

  summary="$(state_summary)"
  status="${summary%%|*}"
  message="${summary#*|}"
  case "${status}" in
    done)
      log "all phases finished."
      break
      ;;
    blocked)
      if is_waiting_message "${message}"; then
        now="$(date +%s)"
        if (( now >= deadline )); then
          die "still waiting after ${TIMEOUT_MINUTES} minutes: ${message}. Re-run this command to keep going."
        fi
        log "waiting: ${message}"
        log "next check in ${POLL_SECONDS}s ($(( (deadline - now) / 60 )) minutes of patience left)"
        sleep "${POLL_SECONDS}"
        continue
      fi
      echo >&2
      die "a phase needs attention: ${message}
After fixing it, re-run this same command; it resumes at that phase."
      ;;
    failed)
      die "the install failed: ${message}. After fixing it, re-run this same command; it resumes at that phase."
      ;;
    *)
      # in_progress / none: the installer returned without finishing (e.g. interrupted). Run it again.
      now="$(date +%s)"
      (( now < deadline )) || die "gave up after ${TIMEOUT_MINUTES} minutes (state: ${status})."
      log "state '${status}'; running the installer again"
      ;;
  esac
done

echo
"${INSTALLER}" "${base_args[@]}" --status || true
cat <<EOF

Done. To reach the product from this machine:
  echo '127.0.0.1  app.straiker.internal defend.straiker.internal ascend.straiker.internal' | sudo tee -a /etc/hosts
  kubectl -n ${NAMESPACE} port-forward svc/straiker-edge 8443:8443
  open https://app.straiker.internal:8443/        (self-signed certificate)
Bootstrap admin: admin@straiker.internal. Password:
  kubectl get secret straiker-secrets -n ${NAMESPACE} -o jsonpath='{.data.BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d; echo
EOF
