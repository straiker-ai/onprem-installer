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

TFBE_SRC="${REPO_ROOT}/terraform/aws/tfbe"
EKS_SRC="${REPO_ROOT}/terraform/aws/eks"

# Same fixed /tmp work root install-straiker.sh uses — destroy needs to see the
# same backend.tf/tfvars/provider cache/local state that install set up there.
TF_WORK_ROOT="${STRAIKER_TF_WORK_ROOT:-/tmp/straiker-tf}"
TFBE_DIR="${TF_WORK_ROOT}/aws/tfbe"
EKS_DIR="${TF_WORK_ROOT}/aws/eks"

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
# to just one. The 5 inference models (charts/straiker-inference — one
# release per model, release name = model name) are always listed regardless
# of which products were actually selected at install time; uninstalling a
# release that was never installed is already a no-op (see phase_helm_uninstall).
declare -a ALL_RELEASES=("straiker-core" "inference-antman" "inference-hulk" "inference-quicksilver" "inference-thor" "inference-vision" "inference-wanda" "inference-thanos" "straiker-system" "straiker-artifact")

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
  --aws-region <region>          Override the region read from install state.
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
  kubectl cluster-info >/dev/null
}

phase_helm_uninstall() {
  local releases=("${ALL_RELEASES[@]}")
  [[ -n "${RELEASE_NAME}" ]] && releases=("${RELEASE_NAME}")

  local release
  for release in "${releases[@]}"; do
    if helm status "${release}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      log "Uninstalling release '${release}'..."
      helm uninstall "${release}" -n "${NAMESPACE}" --wait --timeout "${HELM_TIMEOUT}"
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
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="$(get_install_metadata "aws_region")"
  fi
  if [[ -z "${CLUSTER_NAME}" ]]; then
    CLUSTER_NAME="$(get_install_metadata "cluster_name")"
  fi
  if [[ -z "${TF_PREFIX}" ]]; then
    TF_PREFIX="$(get_install_metadata "tf_prefix")"
  fi
}

confirm_destruction() {
  local expected=$1
  if [[ "${AUTO_YES}" == true ]]; then
    return 0
  fi
  echo "This will permanently destroy EKS cluster '${expected}' and its infrastructure." >&2
  local typed=""
  if ! { read -r -p "Type the cluster name to confirm: " typed < /dev/tty; } 2>/dev/null; then
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

write_eks_tfvars() {
  local azs az1 az2
  azs="$(get_install_metadata "availability_zones")"
  IFS=',' read -r az1 az2 <<< "${azs}"

  if [[ -z "${az1:-}" || -z "${az2:-}" ]]; then
    mark_phase_blocked "Could not determine the availability zones this cluster was created with (missing from install state). Pass a values file or re-run install first."
    return 1
  fi

  cat > "${EKS_DIR}/terraform.auto.tfvars" <<EOF
# Generated by scripts/uninstall-straiker.sh — safe to delete between runs.
region             = "${AWS_REGION}"
availability_zones = ["${az1}", "${az2}"]
cluster_name       = "${CLUSTER_NAME}"
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
    log "Skipping EKS cluster teardown; pass --destroy-eks to also destroy the cluster this installer provisioned. The EKS cluster is untouched."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--destroy-eks not set."
    return
  fi
  if [[ "$(get_install_metadata "install_eks")" != "true" ]]; then
    mark_phase_blocked "Install state does not show this installer provisioned EKS; refusing to destroy. Pass --aws-region/--cluster-name/--tf-prefix explicitly if you're certain, or use ${NUKE_EKS_PATH} (resolves the cluster itself, doesn't need install state)."
    return
  fi

  require_command aws
  require_command tofu
  require_terraform_dir "${EKS_SRC}" || return
  sync_terraform_workdir "${EKS_SRC}" "${EKS_DIR}"

  resolve_destroy_inputs
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

phase_eks_tfbe_destroy() {
  if [[ "${DESTROY_EKS}" != true ]]; then
    log "Skipping Terraform state bucket teardown; pass --destroy-eks to also destroy it."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--destroy-eks not set."
    return
  fi
  if [[ "$(get_install_metadata "install_eks")" != "true" ]]; then
    mark_phase_blocked "Install state does not show this installer provisioned EKS; refusing to destroy. ${NUKE_EKS_PATH} doesn't need install state if you want to tear it down anyway."
    return
  fi

  require_command aws
  require_command tofu
  require_terraform_dir "${TFBE_SRC}" || return

  resolve_destroy_inputs
  if [[ -z "${AWS_REGION}" || -z "${TF_PREFIX}" ]]; then
    mark_phase_blocked "Missing region/tf-prefix (not in install state and not passed explicitly)."
    return
  fi

  if [[ ! -d "${TFBE_DIR}/.terraform" ]]; then
    local bucket_name
    bucket_name="$(get_install_metadata "bootstrap_bucket")"
    [[ -n "${bucket_name}" ]] || bucket_name="$(resolve_bucket_name)"
    mark_phase_blocked "No local Terraform state for the bootstrap bucket on this machine (it was never remote). If you want it gone, delete it manually: aws s3 rb --force s3://${bucket_name}"
    return
  fi

  sync_terraform_workdir "${TFBE_SRC}" "${TFBE_DIR}"
  tofu -chdir="${TFBE_DIR}" init -upgrade -input=false
  tofu -chdir="${TFBE_DIR}" destroy -var="region=${AWS_REGION}" -var="prefix=${TF_PREFIX}" -auto-approve -input=false
}

run_phase() {
  local phase=$1
  local status
  status="$(get_phase_status "${phase}")"

  if [[ "${FORCE_RERUN}" != true && "${status}" == "done" ]]; then
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
