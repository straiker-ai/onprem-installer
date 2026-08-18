#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER_BUNDLE_HOME="${STRAIKER_INSTALLER_BUNDLE_HOME:-${REPO_ROOT}}"

# See install-straiker.sh — same reasoning, needed here since destroy also runs tofu init.
export TF_REGISTRY_CLIENT_TIMEOUT="${TF_REGISTRY_CLIENT_TIMEOUT:-30}"
export TF_PROVIDER_DOWNLOAD_RETRY="${TF_PROVIDER_DOWNLOAD_RETRY:-5}"

STATE_DIR="${HOME}/.straiker"
STATE_FILE="${STATE_DIR}/install.json"
STATE_SECTION="uninstall"
STATE_SCHEMA_VERSION=1

EKS_SRC="${REPO_ROOT}/terraform/aws/eks"
GKE_SRC="${REPO_ROOT}/terraform/gcp/gke"

# Same fixed /tmp work root install-straiker.sh uses — destroy needs to see the
# same backend.tf/tfvars/provider cache/local state that install set up there.
TF_WORK_ROOT="${STRAIKER_TF_WORK_ROOT:-/tmp/straiker-tf}"
EKS_DIR="${TF_WORK_ROOT}/aws/eks"
GKE_DIR="${TF_WORK_ROOT}/gcp/gke"

# Same shared plugin cache install-straiker.sh sets up.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${TF_WORK_ROOT}/plugin-cache}"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

NUKE_EKS_PATH="${INSTALLER_BUNDLE_HOME}/scripts/nuke-eks.sh"

DEFAULT_NAMESPACE="straiker"
DEFAULT_SECRET_NAME="straiker-registry"
DEFAULT_TIMEOUT="15m"

# Every release this installer manages in one namespace — uninstalled in this
# order (app layer before its infra dependency; artifact-sync and the
# inference models have no dependents either way) unless --release narrows it
# to just one. The 7 inference models (charts/straiker-inference — one
# release per model, named 'inference-<model>'), straiker-defend, and
# straiker-ascend are always listed regardless of which products were
# actually selected at install time; uninstalling a release that was never
# installed is already a no-op (see phase_helm_uninstall).
declare -a ALL_RELEASES=("straiker-edge" "straiker-core" "inference-antman" "inference-hulk" "inference-quicksilver" "inference-thor" "inference-vision" "inference-wanda" "inference-thanos" "straiker-defend" "straiker-ascend" "straiker-system" "straiker-artifact")

# These phases are fast, read-only-or-idempotent checks against live cluster
# state (helm/kubectl calls that already no-op cleanly on already-gone
# resources — see phase_helm_uninstall/delete_kept_resources) rather than
# slow provisioning work, so there's no benefit to skipping them via a
# persisted "done" flag the way install-straiker.sh's phases skip expensive
# terraform applies. Worse, that flag goes stale the moment anything gets
# reinstalled after a prior uninstall run (this install.json is shared with
# install-straiker.sh, which never resets these), silently turning a real
# uninstall into a no-op that still reports "completed successfully". Always
# re-verify these against reality instead of trusting the flag.
declare -a ALWAYS_RERUN_PHASES=("preflight" "helm-uninstall" "namespace-cleanup")

NAMESPACE="${DEFAULT_NAMESPACE}"
RELEASE_NAME=""
REGISTRY_SECRET_NAME="${DEFAULT_SECRET_NAME}"
HELM_TIMEOUT="${DEFAULT_TIMEOUT}"

PLAN_ONLY=false
STATUS_ONLY=false
FORCE_RERUN=false
DELETE_NAMESPACE=false

DESTROY_EKS=false
AUTO_YES=false
AWS_REGION="${AWS_REGION:-}"
TF_PREFIX=""
CLUSTER_NAME=""

# Not a flag the customer needs to pass here — resolve_destroy_inputs below
# always reads it from install.json's "install" section (set once, at
# install time, by install-straiker.sh; see that script's CLOUD_PROVIDER
# comment for why it's never reconsidered later). Only falls back to "aws"
# if the state file is missing/predates this field entirely.
CLOUD_PROVIDER="aws"
GCP_REGION=""
GCP_PROJECT_OPT=""

# Same reasoning as CLOUD_PROVIDER above — always read from install state
# (install-straiker.sh's PROVISION_STRATEGY), never a flag here. Needed so
# the regenerated destroy-time tfvars match what was actually applied
# (single_nat_gateway/system node subnet+sizing all key off this) rather
# than silently reverting to install-straiker.sh's current default (which
# is "min" as of this writing, unlike this fallback). This "ha" is
# deliberately NOT that default — it's what every install that predates
# this field entirely actually got (2 AZs, one NAT each, the only behavior
# that existed before provision_strategy was added), so it's what a destroy
# must reconstruct for those, regardless of whatever install-straiker.sh's
# own default happens to be at destroy time.
PROVISION_STRATEGY="ha"

SELECT_PHASE=""
START_PHASE=""

declare -a ALL_PHASES=("preflight" "helm-uninstall" "namespace-cleanup" "eks-cluster-destroy" "eks-tfbe-destroy")
declare -a RUN_PHASES=()
CURRENT_PHASE=""
UNINSTALL_BLOCKED=false
BLOCK_MESSAGE=""

usage() {
  cat <<'EOF'
Usage:
  uninstall-straiker.sh [options]

Options:
  --plan                         Show uninstaller phases and exit.
  --status                       Show state from ~/.straiker/install.json and exit.
  --phase <name>                 Run only one phase.
  --from-phase <name>            Run from phase through the end.
  --rerun-phase                  Re-run selected phases even if already marked done.
  --namespace <name>             Namespace to uninstall from (default: straiker).
  --release <name>               Uninstall only this one release, instead of every Straiker
                                  release in the namespace (straiker-core, straiker-system,
                                  straiker-artifact).
  --timeout <duration>           Helm wait timeout (default: 15m).
  --registry-secret-name <name>  Pull secret to delete along with --delete-namespace (default:
                                  straiker-registry).
  --delete-namespace             Full cleanup: delete resources kept across helm uninstall by
                                  helm.sh/resource-policy=keep (postgres's StatefulSet/Secret,
                                  model PVCs — real data), the registry pull secret, and finally
                                  the namespace itself.
  --destroy-eks                  Also destroy the EKS cluster + state bucket this installer
                                  provisioned via Terraform (--install-eks at install time).
                                  Interactively asks you to type the cluster name to confirm,
                                  unless --yes is also passed. DESTRUCTIVE.
  --yes                          Skip the interactive confirmation for --destroy-eks
                                  (for non-interactive/automated use).
  --aws-region <region>          Override the AWS region read from install state.
  --gcp-region <region>          Override the GCP region read from install state.
  --gcp-project <project-id>     Override the GCP project read from install state.
  --cluster-name <name>          Override the cluster name read from install state.
  --tf-prefix <prefix>           Override the state-bucket prefix read from install state.
  -h, --help                     Show help.
EOF
}

log() {
  echo "[*] $*"
}

require_command() {
  local cmd=$1
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' is not installed or not on PATH." >&2
    exit 1
  fi
}

ensure_state_file() {
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${STATE_FILE}" ]]; then
    python3 - "${STATE_FILE}" "${STATE_SCHEMA_VERSION}" <<'PY'
import json, sys
from datetime import datetime, timezone

path = sys.argv[1]
schema_version = int(sys.argv[2])
now = datetime.now(timezone.utc).isoformat()
data = {
    "schema_version": schema_version,
    "updated_at": now,
    "install": {"status": "not_started", "updated_at": now, "phases": {}, "metadata": {}},
    "uninstall": {"status": "not_started", "updated_at": now, "phases": {}},
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  fi
}

update_state() {
  local section=$1
  local phase=$2
  local status=$3
  local message=${4:-}

  python3 - "${STATE_FILE}" "${section}" "${phase}" "${status}" "${message}" <<'PY'
import json, sys
from datetime import datetime, timezone

path, section, phase, status, message = sys.argv[1:]
now = datetime.now(timezone.utc).isoformat()

with open(path, encoding="utf-8") as f:
    data = json.load(f)

if section not in data:
    data[section] = {"status": "not_started", "updated_at": now, "phases": {}}
section_obj = data[section]
if "phases" not in section_obj:
    section_obj["phases"] = {}

if phase:
    phase_obj = section_obj["phases"].get(phase, {})
    phase_obj["status"] = status
    phase_obj["updated_at"] = now
    if message:
        phase_obj["message"] = message
    section_obj["phases"][phase] = phase_obj

section_obj["status"] = status if phase == "" else section_obj.get("status", "not_started")
section_obj["updated_at"] = now
if message and phase == "":
    section_obj["message"] = message

data["updated_at"] = now

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

set_uninstall_status() {
  local status=$1
  local message=${2:-}
  update_state "${STATE_SECTION}" "" "${status}" "${message}"
}

set_phase_status() {
  local phase=$1
  local status=$2
  local message=${3:-}
  update_state "${STATE_SECTION}" "${phase}" "${status}" "${message}"
}

get_phase_status() {
  local phase=$1
  python3 - "${STATE_FILE}" "${STATE_SECTION}" "${phase}" <<'PY'
import json, sys

path, section, phase = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
print(data.get(section, {}).get("phases", {}).get(phase, {}).get("status", "not_started"))
PY
}

get_install_metadata() {
  local key=$1
  if [[ ! -f "${STATE_FILE}" ]]; then
    return 0
  fi
  python3 - "${STATE_FILE}" "${key}" <<'PY'
import json, sys

path, key = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
print(data.get("install", {}).get("metadata", {}).get(key, ""))
PY
}

show_state() {
  ensure_state_file
  python3 - "${STATE_FILE}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print(json.dumps(data, indent=2, sort_keys=True))
PY
}

show_plan() {
  cat <<'EOF'
Uninstaller phases:
  1) preflight           - Validate local tools and cluster access.
  2) helm-uninstall      - Uninstall Helm release(s) (wait for completion).
  3) namespace-cleanup   - Only with --delete-namespace: delete resources kept across helm
                            uninstall by helm.sh/resource-policy=keep (real data — postgres's
                            StatefulSet/Secret, model PVCs), the registry pull secret, and
                            finally the namespace itself.
  4) eks-cluster-destroy - (optional, requires --destroy-eks) destroy the EKS cluster via Terraform.
  5) eks-tfbe-destroy    - (optional, requires --destroy-eks) destroy the Terraform state bucket.

Notes:
  - Phases 4 and 5 only run with --destroy-eks, and only if install state confirms this
    installer provisioned EKS. They ask you to type the cluster name to confirm, unless
    --yes is also passed. This permanently deletes cloud infrastructure.
EOF
}

is_valid_phase() {
  local wanted=$1
  local phase
  for phase in "${ALL_PHASES[@]}"; do
    if [[ "${phase}" == "${wanted}" ]]; then
      return 0
    fi
  done
  return 1
}

build_phase_list() {
  RUN_PHASES=()
  local phase

  if [[ -n "${SELECT_PHASE}" && -n "${START_PHASE}" ]]; then
    echo "ERROR: --phase and --from-phase cannot be used together." >&2
    exit 1
  fi

  if [[ -n "${SELECT_PHASE}" ]]; then
    if ! is_valid_phase "${SELECT_PHASE}"; then
      echo "ERROR: unknown phase '${SELECT_PHASE}'." >&2
      exit 1
    fi
    RUN_PHASES=("${SELECT_PHASE}")
    return
  fi

  if [[ -n "${START_PHASE}" ]]; then
    if ! is_valid_phase "${START_PHASE}"; then
      echo "ERROR: unknown phase '${START_PHASE}'." >&2
      exit 1
    fi
    local started=false
    for phase in "${ALL_PHASES[@]}"; do
      if [[ "${phase}" == "${START_PHASE}" ]]; then
        started=true
      fi
      if [[ "${started}" == true ]]; then
        RUN_PHASES+=("${phase}")
      fi
    done
    return
  fi

  RUN_PHASES=("${ALL_PHASES[@]}")
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan)
        PLAN_ONLY=true
        shift
        ;;
      --status)
        STATUS_ONLY=true
        shift
        ;;
      --phase)
        SELECT_PHASE=${2:-}
        shift 2
        ;;
      --from-phase)
        START_PHASE=${2:-}
        shift 2
        ;;
      --rerun-phase)
        FORCE_RERUN=true
        shift
        ;;
      --namespace)
        NAMESPACE=${2:-}
        shift 2
        ;;
      --release)
        RELEASE_NAME=${2:-}
        shift 2
        ;;
      --timeout)
        HELM_TIMEOUT=${2:-}
        shift 2
        ;;
      --registry-secret-name)
        REGISTRY_SECRET_NAME=${2:-}
        shift 2
        ;;
      --delete-namespace)
        DELETE_NAMESPACE=true
        shift
        ;;
      --destroy-eks)
        DESTROY_EKS=true
        shift
        ;;
      --yes)
        AUTO_YES=true
        shift
        ;;
      --aws-region)
        AWS_REGION=${2:-}
        shift 2
        ;;
      --gcp-region)
        GCP_REGION=${2:-}
        shift 2
        ;;
      --gcp-project)
        GCP_PROJECT_OPT=${2:-}
        shift 2
        ;;
      --cluster-name)
        CLUSTER_NAME=${2:-}
        shift 2
        ;;
      --tf-prefix)
        TF_PREFIX=${2:-}
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: unknown option '$1'." >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

on_error() {
  local code=$?
  local line=$1
  local message="Failed in phase '${CURRENT_PHASE}' near line ${line}."
  if [[ -n "${CURRENT_PHASE}" ]]; then
    set_phase_status "${CURRENT_PHASE}" "failed" "${message}"
  fi
  set_uninstall_status "failed" "${message}"
  echo "ERROR: ${message}" >&2
  exit "${code}"
}

# See install-straiker.sh's on_interrupt — ERR doesn't fire on signals, so an
# abrupt session/connection death mid-phase needs its own handler.
on_interrupt() {
  local message="Interrupted in phase '${CURRENT_PHASE}' (signal received; the underlying tofu/helm command may have kept running server-side — verify directly before assuming nothing happened)."
  if [[ -n "${CURRENT_PHASE}" ]]; then
    set_phase_status "${CURRENT_PHASE}" "failed" "${message}"
  fi
  set_uninstall_status "failed" "${message}"
  echo "ERROR: ${message}" >&2
  exit 130
}

mark_phase_blocked() {
  local message=$1
  set_phase_status "${CURRENT_PHASE}" "blocked" "${message}"
  set_uninstall_status "blocked" "${message}"
  UNINSTALL_BLOCKED=true
  BLOCK_MESSAGE="${message}"
  log "Phase '${CURRENT_PHASE}' blocked: ${message}"
}

require_terraform_dir() {
  local dir=$1
  if [[ ! -d "${dir}" ]]; then
    mark_phase_blocked "Terraform config not found at '${dir}'. --destroy-eks requires a full clone of straiker-ai/onprem-installer (the installer bundle includes it automatically)."
    return 1
  fi
  return 0
}

# Copies just the .tf sources into the /tmp work dir, leaving .terraform/,
# backend.tf, terraform.auto.tfvars, and any state already there untouched.
sync_terraform_workdir() {
  local src=$1 dest=$2
  mkdir -p "${dest}"
  cp -f "${src}"/*.tf "${dest}/"
}

phase_preflight() {
  require_command helm
  require_command kubectl
  require_command python3
  # Best-effort, not required -- a re-run after a successful --destroy-eks
  # (whose own cleanup_kubeconfig(_gke) already removed the context) has
  # nothing left to reach here, and that's success, not failure. Every
  # phase after this already tolerates an unreachable cluster gracefully on
  # its own (helm-uninstall's `helm status` check per release just reports
  # "does not exist" the same way it would for a genuinely-missing release),
  # so this just logs and moves on rather than hard-failing the whole run
  # before any of that gets a chance to run.
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "Cluster unreachable (already destroyed, or context removed) -- continuing best-effort; later phases no-op cleanly for anything that depends on it."
  fi
}

# Maps a release this script manages to the install-straiker.sh phase that
# installs it, so a real uninstall can invalidate that phase's persisted
# "done" status in install.json's separate "install" section (this script's
# own STATE_SECTION is "uninstall" — a completely different section of the
# same file). Without this, install-straiker.sh --status keeps reporting a
# phase "done" after this script has actually removed its release, and a
# later run trusts that stale flag and silently skips reinstalling it.
install_phase_for_release() {
  case "$1" in
    straiker-core) echo "straiker-core" ;;
    inference-*) echo "straiker-inference" ;;
    straiker-defend) echo "straiker-defend" ;;
    straiker-ascend) echo "straiker-ascend" ;;
    straiker-edge) echo "straiker-edge" ;;
    straiker-system) echo "straiker-system" ;;
    straiker-artifact) echo "artifacts-sync" ;;
    *) echo "" ;;
  esac
}

# `helm uninstall` deletes a release's resources sequentially, in template
# order -- not all at once, and with no awareness of cross-resource
# dependencies. On straiker-system specifically, that means its NodePool/
# ConfigMap can (and does) get deleted before its postgres StatefulSet, whose
# helm.sh/resource-policy=keep annotation means helm never deletes it at all
# (see delete_kept_resources above). Nothing stops the StatefulSet
# controller from noticing its pod is gone and trying to recreate it in that
# gap -- and since it has no idea an uninstall is in progress, it'll keep
# retrying against now-missing dependencies indefinitely (a stray
# replacement node, ConfigMap-not-found mount failures) rather than settling
# on its own. Scaling every Deployment/StatefulSet in the release to 0
# first removes any controller that could react to what gets deleted next,
# regardless of ordering -- and leaves a kept StatefulSet parked at 0
# replicas (clean) instead of stuck retrying forever.
scale_down_release_workloads() {
  local release=$1
  local kind name
  # (kind, name, selector) for each workload scaled down this call -- pods
  # themselves carry no meta.helm.sh/release-name annotation (only the
  # top-level Deployment/StatefulSet does), so the wait step below has to
  # match pods the same way Kubernetes itself does: via each workload's own
  # spec.selector.matchLabels, not by annotation or naming-convention guesses.
  local -a selectors=()

  for kind in deployment statefulset; do
    while IFS=$'\t' read -r name selector; do
      [[ -z "${name}" ]] && continue
      log "Scaling ${kind} '${name}' to 0 before uninstalling '${release}'..."
      kubectl -n "${NAMESPACE}" scale "${kind}" "${name}" --replicas=0 >/dev/null 2>&1 || true
      [[ -n "${selector}" ]] && selectors+=("${selector}")
    done <<< "$(kubectl -n "${NAMESPACE}" get "${kind}" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    ann = item.get('metadata', {}).get('annotations', {}) or {}
    if ann.get('meta.helm.sh/release-name') != '${release}':
        continue
    labels = item.get('spec', {}).get('selector', {}).get('matchLabels', {}) or {}
    selector = ','.join(f'{k}={v}' for k, v in labels.items())
    print(f\"{item['metadata']['name']}\t{selector}\")
")"
  done

  # Best-effort wait for those pods to actually go away -- scale is only
  # updating the spec; termination still takes a grace period. Not fatal if
  # this times out (helm uninstall proceeds regardless), just narrows the
  # window where a pod could still be terminating when the next resource
  # gets deleted.
  local sel waited=0
  while (( waited < 60 )); do
    local any_remaining=false
    for sel in "${selectors[@]+"${selectors[@]}"}"; do
      [[ -z "${sel}" ]] && continue
      local count
      count="$(kubectl -n "${NAMESPACE}" get pods --selector="${sel}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
      [[ "${count}" != "0" ]] && any_remaining=true
    done
    [[ "${any_remaining}" == false ]] && break
    sleep 5
    waited=$((waited + 5))
  done
}

phase_helm_uninstall() {
  local releases=("${ALL_RELEASES[@]}")
  [[ -n "${RELEASE_NAME}" ]] && releases=("${RELEASE_NAME}")

  local release
  for release in "${releases[@]}"; do
    if helm status "${release}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      scale_down_release_workloads "${release}"
      log "Uninstalling release '${release}'..."
      helm uninstall "${release}" -n "${NAMESPACE}" --wait --timeout "${HELM_TIMEOUT}"
      local install_phase
      install_phase="$(install_phase_for_release "${release}")"
      if [[ -n "${install_phase}" ]]; then
        update_state "install" "${install_phase}" "not_started" "Reset by uninstall-straiker.sh after removing release '${release}'."
      fi
    else
      log "Release '${release}' does not exist in namespace '${NAMESPACE}'; skipping."
    fi
  done
}

# Resources annotated helm.sh/resource-policy=keep (postgres's StatefulSet +
# Secret, plus any GPU model PVCs) survive `helm uninstall` on purpose — that
# annotation only protects against Helm's own deletion logic, not a raw
# `kubectl delete namespace` (which cascades to everything regardless). So a
# real --delete-namespace already destroys these too; this just makes that
# explicit in the log instead of leaving it as a silent side effect of the
# namespace-wide cascade, since these specifically hold real data (postgres
# PGDATA, model files).
find_kept_resources() {
  local kind=$1
  kubectl -n "${NAMESPACE}" get "${kind}" -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    ann = item.get("metadata", {}).get("annotations", {}) or {}
    if ann.get("helm.sh/resource-policy") == "keep":
        print(item["metadata"]["name"])
'
}

delete_kept_resources() {
  local kind name
  for kind in statefulset secret pvc; do
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      log "Deleting ${kind} '${name}' (kept across helm uninstall by helm.sh/resource-policy=keep)..."
      kubectl -n "${NAMESPACE}" delete "${kind}" "${name}" --ignore-not-found >/dev/null
    done <<< "$(find_kept_resources "${kind}")"
  done
}

phase_namespace_cleanup() {
  if [[ "${DELETE_NAMESPACE}" != true ]]; then
    log "Skipping namespace cleanup; pass --delete-namespace to enable."
    return
  fi
  delete_kept_resources
  kubectl delete secret "${REGISTRY_SECRET_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
  log "Secret '${REGISTRY_SECRET_NAME}' removed from namespace '${NAMESPACE}'."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null
  log "Namespace '${NAMESPACE}' deletion requested."
}

resolve_destroy_inputs() {
  # cloud_provider is set once at install time and never reconsidered (see
  # the CLOUD_PROVIDER declaration above) — always trust install state over
  # any local default here, there is no flag to override it.
  local recorded_provider
  recorded_provider="$(get_install_metadata "cloud_provider")"
  [[ -n "${recorded_provider}" ]] && CLOUD_PROVIDER="${recorded_provider}"

  if [[ -z "${CLUSTER_NAME}" ]]; then
    CLUSTER_NAME="$(get_install_metadata "cluster_name")"
  fi
  if [[ -z "${TF_PREFIX}" ]]; then
    TF_PREFIX="$(get_install_metadata "tf_prefix")"
  fi

  local recorded_strategy
  recorded_strategy="$(get_install_metadata "provision_strategy")"
  [[ -n "${recorded_strategy}" ]] && PROVISION_STRATEGY="${recorded_strategy}"

  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    if [[ -z "${GCP_REGION}" ]]; then
      GCP_REGION="$(get_install_metadata "gcp_region")"
    fi
    if [[ -z "${GCP_PROJECT_OPT}" ]]; then
      GCP_PROJECT_OPT="$(get_install_metadata "gcp_project")"
    fi
  else
    if [[ -z "${AWS_REGION}" ]]; then
      AWS_REGION="$(get_install_metadata "aws_region")"
    fi
  fi
}

confirm_destruction() {
  local expected=$1
  if [[ "${AUTO_YES}" == true ]]; then
    return 0
  fi
  echo "This will permanently destroy cluster '${expected}' and its infrastructure." >&2
  # read -p's prompt only prints when read's OWN stdin is a terminal at the
  # point bash decides whether to show it -- under `curl | bash`, this
  # script's stdin is the pipe from curl, not a tty, so despite the
  # `< /dev/tty` redirect on this command making the actual read work fine,
  # the -p prompt text itself silently never appears (confirmed live: typing
  # blind still worked). Writing the prompt directly to /dev/tty first, then
  # a bare `read` with no -p, sidesteps that entirely -- same fix
  # install-straiker.sh's prompt_line() already uses.
  if [[ ! -e /dev/tty ]] || ! printf '%s' "Type the cluster name to confirm: " 2>/dev/null > /dev/tty; then
    mark_phase_blocked "No interactive terminal available to confirm destruction. Re-run with --yes if you're sure."
    return 1
  fi
  local typed=""
  if ! read -r typed < /dev/tty; then
    mark_phase_blocked "No interactive terminal available to confirm destruction. Re-run with --yes if you're sure."
    return 1
  fi
  if [[ "${typed}" != "${expected}" ]]; then
    mark_phase_blocked "Confirmation did not match cluster name '${expected}'; aborting destroy."
    return 1
  fi
  return 0
}

write_eks_backend_config() {
  local bucket_name=$1
  cat > "${EKS_DIR}/backend.tf" <<EOF
# Generated by scripts/uninstall-straiker.sh — safe to delete between runs.
terraform {
  backend "s3" {
    bucket       = "${bucket_name}"
    key          = "s6r-onprem/terraform.tfstate"
    region       = "${AWS_REGION}"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
}

write_gke_backend_config() {
  local bucket_name=$1
  local dir=$2
  local key=$3
  cat > "${dir}/backend.tf" <<EOF
# Generated by scripts/uninstall-straiker.sh — safe to delete between runs.
terraform {
  backend "gcs" {
    bucket = "${bucket_name}"
    prefix = "s6r-onprem/${key}"
  }
}
EOF
}

write_eks_tfvars() {
  # Reconstructs the FULL list regardless of count (2 for min/ha, 3 for
  # max — see install-straiker.sh's write_eks_tfvars) rather than assuming
  # exactly 2; hardcoding 2 here would silently drop a 3rd AZ under
  # provision_strategy=max and could leave its resources out of the destroy
  # plan entirely.
  local azs az_json
  azs="$(get_install_metadata "availability_zones")"

  if [[ -z "${azs}" ]]; then
    mark_phase_blocked "Could not determine the availability zones this cluster was created with (missing from install state). Pass a values file or re-run install first."
    return 1
  fi

  az_json="$(IFS=','; printf '"%s", ' ${azs})"
  az_json="[${az_json%, }]"

  cat > "${EKS_DIR}/terraform.auto.tfvars" <<EOF
# Generated by scripts/uninstall-straiker.sh — safe to delete between runs.
region             = "${AWS_REGION}"
availability_zones = ${az_json}
cluster_name       = "${CLUSTER_NAME}"
provision_strategy = "${PROVISION_STRATEGY}"
EOF
  return 0
}

resolve_bucket_name() {
  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  echo "${TF_PREFIX}-tfstate-${AWS_REGION}-${account_id}"
}

phase_eks_cluster_destroy() {
  if [[ "${DESTROY_EKS}" != true ]]; then
    log "Skipping cluster teardown; pass --destroy-eks to also destroy the cluster this installer provisioned. The cluster is untouched."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--destroy-eks not set."
    return
  fi
  if [[ "$(get_install_metadata "install_eks")" != "true" ]]; then
    mark_phase_blocked "Install state does not show this installer provisioned the cluster; refusing to destroy. Pass --aws-region/--cluster-name/--tf-prefix explicitly if you're certain, or use ${NUKE_EKS_PATH} (resolves the cluster itself, doesn't need install state; AWS only)."
    return
  fi

  resolve_destroy_inputs
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    phase_eks_cluster_destroy_gke
    return
  fi

  require_command aws
  require_command tofu
  require_terraform_dir "${EKS_SRC}" || return
  sync_terraform_workdir "${EKS_SRC}" "${EKS_DIR}"

  if [[ -z "${AWS_REGION}" || -z "${CLUSTER_NAME}" || -z "${TF_PREFIX}" ]]; then
    mark_phase_blocked "Missing region/cluster-name/tf-prefix (not in install state and not passed explicitly). Use ${NUKE_EKS_PATH} instead if you don't have these on hand."
    return
  fi

  local bucket_name
  bucket_name="$(get_install_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    bucket_name="$(resolve_bucket_name)"
  fi
  if ! aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
    log "State bucket '${bucket_name}' not found; nothing to destroy."
    return
  fi

  write_eks_backend_config "${bucket_name}"
  write_eks_tfvars || return

  confirm_destruction "${CLUSTER_NAME}" || return

  terminate_karpenter_nodes
  tofu -chdir="${EKS_DIR}" init -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${EKS_DIR}" destroy -auto-approve -input=false
  verify_cluster_gone
  cleanup_kubeconfig
}

resolve_bucket_name_gcp() {
  echo "${TF_PREFIX}-tfstate-${GCP_REGION}-${GCP_PROJECT_OPT}"
}

phase_eks_cluster_destroy_gke() {
  require_command gcloud
  require_command tofu
  require_terraform_dir "${GKE_SRC}" || return
  sync_terraform_workdir "${GKE_SRC}" "${GKE_DIR}"

  if [[ -z "${GCP_REGION}" || -z "${GCP_PROJECT_OPT}" || -z "${CLUSTER_NAME}" || -z "${TF_PREFIX}" ]]; then
    mark_phase_blocked "Missing gcp-region/gcp-project/cluster-name/tf-prefix (not in install state and not passed explicitly)."
    return
  fi

  local bucket_name
  bucket_name="$(get_install_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    bucket_name="$(resolve_bucket_name_gcp)"
  fi
  if ! gcloud storage buckets describe "gs://${bucket_name}" >/dev/null 2>&1; then
    log "State bucket '${bucket_name}' not found; nothing to destroy."
    return
  fi

  write_gke_backend_config "${bucket_name}" "${GKE_DIR}" "gke"

  confirm_destruction "${CLUSTER_NAME}" || return

  terminate_karpenter_nodes_gke
  tofu -chdir="${GKE_DIR}" init -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${GKE_DIR}" destroy -auto-approve -input=false \
    -var="region=${GCP_REGION}" -var="project_id=${GCP_PROJECT_OPT}" -var="cluster_name=${CLUSTER_NAME}"
  verify_cluster_gone_gke
  cleanup_kubeconfig_gke
}

# Karpenter provisions EC2 nodes directly via the AWS API — they are never in
# Terraform state, so `tofu destroy` on the VPC/EKS module can hang or fail on
# leftover ENIs/security-group attachments unless these are torn down first.
terminate_karpenter_nodes() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "kubectl not reachable — skipping Karpenter NodePool cleanup (tofu destroy may hang on orphaned nodes)."
    return
  fi

  log "Deleting Karpenter NodePools/EC2NodeClasses..."
  kubectl delete nodepools --all --wait=false >/dev/null 2>&1 || true
  kubectl delete ec2nodeclasses --all --wait=false >/dev/null 2>&1 || true

  local instance_ids count
  instance_ids="$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || echo "")"

  if [[ -z "${instance_ids}" || "${instance_ids}" == "None" ]]; then
    log "No Karpenter-provisioned EC2 instances found for cluster '${CLUSTER_NAME}'."
    return
  fi

  count="$(echo "${instance_ids}" | wc -w | tr -d ' ')"
  log "Terminating ${count} Karpenter-provisioned instance(s)..."
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids ${instance_ids} >/dev/null
  log "Waiting for termination (up to 10 min)..."
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids ${instance_ids}
}

# tofu destroy can report success with 0 resources destroyed if state was ever
# out of sync — always verify the cluster is actually gone, and fall back to
# the AWS API directly (node groups block cluster deletion until removed).
verify_cluster_gone() {
  if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    return
  fi

  log "Cluster still exists after tofu destroy — falling back to the AWS API."
  local node_groups ng
  node_groups="$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'nodegroups[]' --output text 2>/dev/null || echo "")"
  if [[ -n "${node_groups}" && "${node_groups}" != "None" ]]; then
    for ng in ${node_groups}; do
      log "Deleting node group '${ng}'..."
      aws eks delete-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${ng}" \
        --region "${AWS_REGION}" >/dev/null 2>&1 || true
    done
    for ng in ${node_groups}; do
      aws eks wait nodegroup-deleted --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${ng}" \
        --region "${AWS_REGION}" 2>/dev/null || true
    done
  fi

  log "Deleting EKS cluster '${CLUSTER_NAME}' via the AWS API..."
  aws eks delete-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" || true
  aws eks wait cluster-deleted --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>/dev/null || true

  if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    log "WARNING: cluster '${CLUSTER_NAME}' still exists — likely a stuck VPC dependency (NAT gateway, load balancer). Run ${NUKE_EKS_PATH} to clean up the remainder."
  fi
}

cleanup_kubeconfig() {
  local account ctx
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
  [[ -n "${account}" ]] || return
  ctx="arn:aws:eks:${AWS_REGION}:${account}:cluster/${CLUSTER_NAME}"
  kubectl config delete-context "${ctx}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${ctx}" >/dev/null 2>&1 || true
  kubectl config unset "users.${ctx}" >/dev/null 2>&1 || true
}

# Karpenter (cloudpilot-ai/karpenter-provider-gcp) provisions GCE instances
# directly via the Compute API — never in Terraform state — and stamps each
# one with the "goog-k8s-cluster-name" label (verified 2026-08 against
# pkg/utils/utils.go and pkg/providers/instance/instance.go in that repo;
# this is the same label its own GC controller and syncInstances filter use
# to recognize instances as belonging to this cluster). Mirrors
# terminate_karpenter_nodes' AWS tag-filter approach.
terminate_karpenter_nodes_gke() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "kubectl not reachable — skipping Karpenter NodePool cleanup (tofu destroy may hang on orphaned nodes)."
    return
  fi

  log "Deleting Karpenter NodePools/GCENodeClasses..."
  kubectl delete nodepools --all --wait=false >/dev/null 2>&1 || true
  kubectl delete gcenodeclasses --all --wait=false >/dev/null 2>&1 || true

  local instances line name zone
  instances="$(gcloud compute instances list \
    --project "${GCP_PROJECT_OPT}" \
    --filter="labels.goog-k8s-cluster-name=${CLUSTER_NAME}" \
    --format="csv[no-heading](name,zone)" 2>/dev/null || echo "")"

  if [[ -z "${instances}" ]]; then
    log "No Karpenter-provisioned instances found for cluster '${CLUSTER_NAME}'."
    return
  fi

  local count
  count="$(echo "${instances}" | wc -l | tr -d ' ')"
  log "Deleting ${count} Karpenter-provisioned instance(s)..."
  while IFS=',' read -r name zone; do
    [[ -n "${name}" ]] || continue
    gcloud compute instances delete "${name}" --zone "${zone}" --project "${GCP_PROJECT_OPT}" \
      --quiet --async >/dev/null 2>&1 || true
  done <<< "${instances}"

  log "Waiting for deletion..."
  while IFS=',' read -r name zone; do
    [[ -n "${name}" ]] || continue
    gcloud compute instances describe "${name}" --zone "${zone}" --project "${GCP_PROJECT_OPT}" \
      >/dev/null 2>&1 && { sleep 5; } || true
  done <<< "${instances}"
}

# tofu destroy can report success with 0 resources destroyed if state was
# ever out of sync — always verify the cluster is actually gone, and fall
# back to the GCP API directly. Mirrors verify_cluster_gone's AWS fallback
# (GKE clusters don't have the node-group-blocks-deletion issue EKS does,
# so there's no equivalent node-pool-first step needed here).
verify_cluster_gone_gke() {
  if ! gcloud container clusters describe "${CLUSTER_NAME}" --region "${GCP_REGION}" \
    --project "${GCP_PROJECT_OPT}" >/dev/null 2>&1; then
    return
  fi

  log "Cluster still exists after tofu destroy — deleting it directly via the GCP API..."
  gcloud container clusters delete "${CLUSTER_NAME}" --region "${GCP_REGION}" \
    --project "${GCP_PROJECT_OPT}" --quiet || true

  if gcloud container clusters describe "${CLUSTER_NAME}" --region "${GCP_REGION}" \
    --project "${GCP_PROJECT_OPT}" >/dev/null 2>&1; then
    log "WARNING: cluster '${CLUSTER_NAME}' still exists — likely a stuck network dependency (Cloud NAT, firewall rule, load balancer). Check the GCP Console/gcloud for leftover resources in project '${GCP_PROJECT_OPT}'."
  fi
}

# `gcloud container clusters get-credentials` names the kubeconfig
# context/cluster/user entries "gke_<project>_<location>_<cluster-name>" —
# a stable, documented gcloud convention (not chart/version-specific, unlike
# the Karpenter details above, so not separately verified via source).
cleanup_kubeconfig_gke() {
  local ctx="gke_${GCP_PROJECT_OPT}_${GCP_REGION}_${CLUSTER_NAME}"
  kubectl config delete-context "${ctx}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${ctx}" >/dev/null 2>&1 || true
  kubectl config unset "users.${ctx}" >/dev/null 2>&1 || true
}

phase_eks_tfbe_destroy() {
  if [[ "${DESTROY_EKS}" != true ]]; then
    log "Skipping Terraform state bucket teardown; pass --destroy-eks to also destroy it."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--destroy-eks not set."
    return
  fi
  if [[ "$(get_install_metadata "install_eks")" != "true" ]]; then
    mark_phase_blocked "Install state does not show this installer provisioned the cluster; refusing to destroy. ${NUKE_EKS_PATH} doesn't need install state if you want to tear it down anyway (AWS only)."
    return
  fi

  resolve_destroy_inputs
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    phase_eks_tfbe_destroy_gke
    return
  fi

  # Deliberately never auto-destroyed (confirmed live: it just fails anyway
  # -- BucketNotEmpty. Both this module's aws_s3_bucket.tfstate and its GCS
  # equivalent set force_destroy=false and enable versioning on purpose, so
  # `tofu destroy` can never actually empty a bucket that's ever taken a
  # real write, which by this point it always has). It's also the backend
  # holding the state for the destroy that just ran — tearing down your own
  # backend automatically, right after using it, isn't something to do
  # without a deliberate separate decision either way.
  local bucket_name
  bucket_name="$(get_install_metadata "bootstrap_bucket")"
  [[ -n "${bucket_name}" ]] || bucket_name="$(resolve_bucket_name)"
  log "Leaving Terraform state bucket '${bucket_name}' in place — never auto-destroyed (it holds versioned history, including this destroy's own state; force_destroy=false is deliberate)."
  log "To remove it yourself: purge every version first, then delete the bucket --"
  log "  aws s3api delete-objects --bucket ${bucket_name} --delete \"\$(aws s3api list-object-versions --bucket ${bucket_name} --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')\""
  log "  aws s3api delete-objects --bucket ${bucket_name} --delete \"\$(aws s3api list-object-versions --bucket ${bucket_name} --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')\""
  log "  aws s3api delete-bucket --bucket ${bucket_name}"
  set_phase_status "${CURRENT_PHASE}" "skipped" "State bucket left in place by design; see log above for manual removal."
}

phase_eks_tfbe_destroy_gke() {
  local bucket_name
  bucket_name="$(get_install_metadata "bootstrap_bucket")"
  [[ -n "${bucket_name}" ]] || bucket_name="$(resolve_bucket_name_gcp)"
  log "Leaving Terraform state bucket '${bucket_name}' in place — never auto-destroyed (it holds versioned history, including this destroy's own state; force_destroy=false is deliberate)."
  log "To remove it yourself (this bucket has object versioning on, so a plain 'rm --recursive' will leave old generations behind and fail the same way):"
  log "  gcloud storage rm --recursive --all-versions gs://${bucket_name}"
  set_phase_status "${CURRENT_PHASE}" "skipped" "State bucket left in place by design; see log above for manual removal."
}

run_phase() {
  local phase=$1
  local status
  status="$(get_phase_status "${phase}")"

  local always_rerun=false p
  for p in "${ALWAYS_RERUN_PHASES[@]}"; do
    [[ "${phase}" == "${p}" ]] && always_rerun=true
  done

  if [[ "${always_rerun}" != true && "${FORCE_RERUN}" != true && "${status}" == "done" ]]; then
    log "Skipping '${phase}' (already done). Use --rerun-phase to force."
    return
  fi

  CURRENT_PHASE="${phase}"
  set_phase_status "${phase}" "in_progress"
  log "Phase '${phase}'..."

  case "${phase}" in
    preflight) phase_preflight ;;
    helm-uninstall) phase_helm_uninstall ;;
    namespace-cleanup) phase_namespace_cleanup ;;
    eks-cluster-destroy) phase_eks_cluster_destroy ;;
    eks-tfbe-destroy) phase_eks_tfbe_destroy ;;
    *)
      echo "ERROR: phase '${phase}' is not implemented." >&2
      exit 1
      ;;
  esac

  status="$(get_phase_status "${phase}")"
  if [[ "${status}" == "blocked" || "${status}" == "skipped" ]]; then
    return
  fi
  set_phase_status "${phase}" "done"
}

main() {
  trap 'on_error $LINENO' ERR
  trap on_interrupt HUP INT TERM
  parse_args "$@"
  ensure_state_file

  if [[ "${PLAN_ONLY}" == true ]]; then
    show_plan
    exit 0
  fi

  if [[ "${STATUS_ONLY}" == true ]]; then
    show_state
    exit 0
  fi

  build_phase_list

  set_uninstall_status "in_progress" "Uninstaller started."
  update_state "${STATE_SECTION}" "" "in_progress" "namespace=${NAMESPACE}, release=${RELEASE_NAME:-<all>}"

  local phase
  for phase in "${RUN_PHASES[@]}"; do
    run_phase "${phase}"
    if [[ "${UNINSTALL_BLOCKED}" == true ]]; then
      log "Uninstaller paused: ${BLOCK_MESSAGE}"
      log "Fix prerequisites and rerun the uninstaller."
      exit 0
    fi
  done

  set_uninstall_status "done" "Uninstaller completed."
  log "Uninstall completed successfully."
  if [[ "${DESTROY_EKS}" != true ]]; then
    log "Note: --destroy-eks was not set — the EKS cluster and its cloud infrastructure were NOT touched, only the Helm release."
  fi
  log "State file: ${STATE_FILE}"
}

main "$@"
