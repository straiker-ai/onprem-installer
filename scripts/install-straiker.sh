#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# OpenTofu's default registry client timeout (10s) is too short for large
# providers (hashicorp/aws in particular) on slow connections — small providers
# finish in time, aws doesn't. Bump both unless the caller already set these.
export TF_REGISTRY_CLIENT_TIMEOUT="${TF_REGISTRY_CLIENT_TIMEOUT:-30}"
export TF_PROVIDER_DOWNLOAD_RETRY="${TF_PROVIDER_DOWNLOAD_RETRY:-5}"

STATE_DIR="${HOME}/.straiker"
STATE_FILE="${STATE_DIR}/install.json"
STATE_SECTION="install"
STATE_SCHEMA_VERSION=1
INSTALLER_BUNDLE_VERSION="${STRAIKER_INSTALLER_BUNDLE_VERSION:-workspace}"
INSTALLER_BUNDLE_HOME="${STRAIKER_INSTALLER_BUNDLE_HOME:-${REPO_ROOT}}"
INSTALLER_BUNDLE_URL="${STRAIKER_INSTALLER_BUNDLE_URL:-}"

TFBE_SRC="${REPO_ROOT}/terraform/aws/tfbe"
EKS_SRC="${REPO_ROOT}/terraform/aws/eks"
ARTIFACTS_SRC="${REPO_ROOT}/terraform/aws/artifacts"

# Actual tofu runs happen under /tmp, not the bundle dir under $HOME — provider
# plugin downloads are hundreds of MB and $HOME may be tiny (e.g. AWS CloudShell's
# 1 GB home volume). A fixed path (not mktemp) lets .terraform/ provider caches
# and generated backend/tfvars survive across separate phase invocations.
TF_WORK_ROOT="${STRAIKER_TF_WORK_ROOT:-/tmp/straiker-tf}"
TFBE_DIR="${TF_WORK_ROOT}/aws/tfbe"
EKS_DIR="${TF_WORK_ROOT}/aws/eks"
ARTIFACTS_DIR="${TF_WORK_ROOT}/aws/artifacts"

# terraform/aws/eks's karpenter.tf only provisions the AWS-side IAM/SQS/pod-identity
# resources — it does not install the Karpenter controller itself. This installs
# it via its OCI chart, using the pod identity association Terraform already set up
# (namespace/service-account "karpenter", matching the module's defaults).
KARPENTER_VERSION="1.14.0"
KARPENTER_NAMESPACE="karpenter"

# Straiker's own source images/bucket live in charts/straiker-artifact/values.yaml
# (imageMirror.images, each with its own full source URL, and modelSync.sourceBucket)
# — not here. They're fixed for this project (only the per-customer credential,
# --straiker-credential-file, grants access to them), so the installer doesn't
# need to pass them per-invocation.

# Shared provider plugin cache across tfbe and eks (both need hashicorp/aws) and
# across separate invocations — avoids re-downloading the same large provider
# twice in one run, or ever again as long as /tmp/straiker-tf survives.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${TF_WORK_ROOT}/plugin-cache}"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

HELM_REPO_NAME="straiker"
HELM_REPO_URL="https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist"
INFRA_RELEASE="straiker-system"
# Single namespace shared by every Straiker chart this installer manages
# (straiker-system, straiker-artifact, straiker-core, and future per-product
# charts) — not to be confused with the straiker-system *chart/release name*
# below, which stays "straiker-system" regardless of namespace. Resolved (flag/
# persisted/prompt, defaulting to "straiker") by capture_install_config.
INFRA_NAMESPACE=""
INFRA_CHART_NAME="straiker-system"
# Installed (into the same INFRA_NAMESPACE as straiker-system) and polled to
# completion in phase_artifacts_sync, before straiker-system-helm — that chart's
# workloads pull images through the ECR mirror this chart populates.
ARTIFACT_RELEASE="straiker-artifact"
ARTIFACT_CHART_NAME="straiker-artifact"
# Must match charts/straiker-artifact's default straikerCredentialSecretName.
STRAIKER_CREDENTIAL_SECRET_NAME="straiker-credential"

# Application layer (frontend/bifrost/glauth/dex/caddy) — a standalone chart
# (formerly nested under a now-sunset charts/straiker umbrella), installed
# into the same INFRA_NAMESPACE, after straiker-system-helm. Other products
# (Ascend/Defend/...) will land as their own separate phases/charts, not
# folded back into one umbrella — this is the first of several small charts.
APP_RELEASE="straiker-core"
APP_CHART_NAME="straiker-core"

AWS_REGION="${AWS_REGION:-}"
# Only exported (see main()) if --aws-profile is passed — otherwise leave
# whatever AWS_PROFILE the caller's shell already has alone. Every aws/tofu
# call below is bare (no --profile flag), so without one of these two, a
# non-default SSO profile session never actually reaches those commands even
# after `aws sso login --profile X` — they'd silently fall back to the
# default profile's (missing) credentials.
AWS_PROFILE_OPT="${AWS_PROFILE:-}"
TF_PREFIX="s6r-onprem"
CLUSTER_NAME=""
INSTALL_EKS=false
INSTALL_EKS_EXPLICIT=false
AUTO_YES=false
PLAN_ONLY=false
STATUS_ONLY=false
FORCE_RERUN=false

SELECT_PHASE=""
START_PHASE=""
CHART_VERSION=""
HELM_TIMEOUT="20m"
STRAIKER_CREDENTIAL_FILE=""
# Comma-separated canonical product names (ascend, defend — discover/pathfinder
# isn't implemented yet), resolved/persisted by capture_install_config.
PRODUCTS_OPT=""

declare -a VALUES_FILES=()
declare -a ALL_PHASES=("eks-tfbe" "eks-cluster" "karpenter" "k8s-preflight" "aws-artifacts" "artifacts-sync" "straiker-system-helm" "straiker-core-helm")
declare -a RUN_PHASES=()

CURRENT_PHASE=""
INSTALL_BLOCKED=false
BLOCK_MESSAGE=""

usage() {
  cat <<'EOF'
Usage:
  install-straiker.sh [options]

Options:
  --plan                          Show installer phases and exit.
  --status                        Show install state from ~/.straiker/install.json and exit.
  --phase <name>                  Run only one phase.
  --from-phase <name>             Run from phase through the end.
  --rerun-phase                   Re-run selected phases even if already marked done.
  --install-eks                   Also provision an EKS cluster via Terraform (the AWS
                                   bootstrap phase runs regardless of this flag).
  --yes                           Skip the interactive resource-creation acknowledgement
                                   (for non-interactive/automated use).
  --aws-region <region>           AWS region (falls back to AWS_REGION/AWS_DEFAULT_REGION env,
                                   then the AWS CLI's configured region).
  --aws-profile <name>            AWS CLI/SSO profile for every aws/tofu command this installer
                                   runs (falls back to the AWS_PROFILE env var). Needed whenever
                                   your credentials live under a non-default profile — otherwise
                                   `aws sso login --profile X` alone won't reach these commands.
  --tf-prefix <prefix>            Prefix for the Terraform state bucket (default: s6r-onprem).
  --cluster-name <name>           EKS cluster name (default: s6r-onprem with --install-eks;
                                   otherwise auto-detected from the current kubectl context).
  --namespace <name>              Kubernetes namespace for every Straiker chart (straiker-system,
                                   straiker-artifact, straiker-core, ...). Default: straiker.
                                   If omitted, you'll be prompted interactively.
  --repo-name <name>              Helm repo name (default: straiker).
  --repo-url <url>                Helm repo URL (default: public dist repo).
  --chart-version <version>       Optional straiker-system chart version.
  --values <file>                 Values file for the straiker-system release (repeatable).
  --straiker-credential-file <path>
                                   Path to the per-customer JSON credential file Straiker
                                   provides (contact your rep if you don't have one). Required
                                   — if omitted, you'll be prompted interactively.
  --products <list>               Comma-separated products to provision infra for: ascend,
                                   defend (discover isn't available yet). Required — at least
                                   one. Determines which Karpenter NodePools straiker-system-helm
                                   enables. Shared system services (OpenSearch/Postgres/Redis)
                                   install either way. If omitted, you'll be prompted interactively.
  --timeout <duration>            Helm wait timeout (default: 20m).
  -h, --help                      Show this help.
EOF
}

log() {
  # Always stderr, never stdout: several functions (check_artifact_job,
  # normalize_products) call log() while their actual return value is
  # captured via "$(...)" — if log() wrote to stdout, that capture would
  # silently include the log line too, corrupting the value.
  if [[ -t 2 ]]; then
    printf '\033[1;36m[*]\033[0m %s\n' "$*" >&2
  else
    echo "[*] $*" >&2
  fi
}

require_command() {
  local cmd=$1
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' is not installed or not on PATH." >&2
    exit 1
  fi
}

resolve_aws_region() {
  if [[ -n "${AWS_REGION}" ]]; then
    return
  fi
  # AWS CloudShell (and some CLI setups) only export the legacy AWS_DEFAULT_REGION.
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    AWS_REGION="${AWS_DEFAULT_REGION}"
    return
  fi
  if command -v aws >/dev/null 2>&1; then
    AWS_REGION="$(aws configure get region 2>/dev/null || true)"
  fi
}

resolve_cluster_name() {
  if [[ -n "${CLUSTER_NAME}" ]]; then
    return
  fi
  # Bring-your-own-cluster: auto-detect from the current kubeconfig context
  # rather than defaulting straight to "s6r-onprem", which is almost certainly
  # not this cluster's real name. EKS contexts are ARNs ending in
  # "cluster/<name>"; --install-eks always provisions "s6r-onprem" itself, so
  # skip detection there and use that default directly.
  if [[ "${INSTALL_EKS}" != true ]] && command -v kubectl >/dev/null 2>&1; then
    local context
    context="$(kubectl config current-context 2>/dev/null || true)"
    if [[ -n "${context}" && "${context}" == */* ]]; then
      CLUSTER_NAME="${context##*/}"
      log "Auto-detected cluster name '${CLUSTER_NAME}' from current kubectl context."
      return
    fi
  fi
  CLUSTER_NAME="s6r-onprem"
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
    data[section] = {"status": "not_started", "updated_at": now, "phases": {}, "metadata": {}}
section_obj = data[section]
section_obj.setdefault("phases", {})
section_obj.setdefault("metadata", {})

if phase:
    phase_obj = section_obj["phases"].get(phase, {})
    phase_obj["status"] = status
    phase_obj["updated_at"] = now
    if message:
        phase_obj["message"] = message
    section_obj["phases"][phase] = phase_obj
else:
    section_obj["status"] = status
    if message:
        section_obj["message"] = message

section_obj["updated_at"] = now
data["updated_at"] = now

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

set_install_status() {
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

set_metadata() {
  local key=$1
  local value=$2
  python3 - "${STATE_FILE}" "${STATE_SECTION}" "${key}" "${value}" <<'PY'
import json, sys
from datetime import datetime, timezone

path, section, key, value = sys.argv[1:]
now = datetime.now(timezone.utc).isoformat()

with open(path, encoding="utf-8") as f:
    data = json.load(f)

if section not in data:
    data[section] = {"status": "not_started", "updated_at": now, "phases": {}, "metadata": {}}
section_obj = data[section]
section_obj.setdefault("metadata", {})
section_obj["metadata"][key] = value
section_obj["updated_at"] = now
data["updated_at"] = now

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

get_metadata() {
  local key=$1
  python3 - "${STATE_FILE}" "${STATE_SECTION}" "${key}" <<'PY'
import json, sys

path, section, key = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
print(data.get(section, {}).get("metadata", {}).get(key, ""))
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
Installer phases:
  1) eks-tfbe             - create the S3 Terraform state bucket. Always runs.
  2) eks-cluster          - (optional, requires --install-eks) provision the EKS cluster + Karpenter IAM via Terraform.
  3) karpenter            - (optional, requires --install-eks) install the Karpenter controller itself
                             (its OCI chart) using the IAM/SQS/pod-identity Terraform already set up.
                             The straiker-system chart's NodePools need this CRD installed first.
  4) k8s-preflight        - Always runs. Confirms the cluster is actually usable before going
                             further: kubectl reachable, a StorageClass opensearch's/postgres's PVCs can use
                             exists (prefers a real default, falls back to the lone StorageClass
                             if there's exactly one, only blocks if that's ambiguous or missing
                             entirely), and (only when --install-eks was NOT used, since our
                             own eks-cluster/karpenter phases already prove it otherwise) that the
                             customer's own Karpenter has its CRDs installed and a healthy
                             controller. Catches these here, rather than straiker-system-helm
                             hanging for its full --wait timeout or failing late and unclearly.
  5) aws-artifacts        - create the ECR image mirror + models S3 bucket + hauler IAM role
                             (EKS Pod Identity). Always runs; needs a cluster to already exist
                             (ours via eks-cluster, or the customer's own via --cluster-name).
  6) artifacts-sync       - install/upgrade release 'straiker-artifact' (its own chart), which
                             creates the K8s Secret and runs the in-cluster image-mirror/model-sync
                             Jobs (plain resources, not Helm hooks — they can run for hours without
                             blocking this command). --straiker-credential-file is required; you'll
                             be prompted for it interactively if omitted. Blocks the installer here
                             until both Jobs report complete — re-run --phase artifacts-sync any
                             time to check again — since straiker-system-helm's workloads pull
                             images through the ECR mirror these Jobs populate.
  7) straiker-system-helm - add the public straiker Helm repo and install/upgrade release
                             'straiker-system'. Runs only after artifacts-sync completes.
  8) straiker-core-helm   - install/upgrade release 'straiker-core' (frontend, bifrost, glauth,
                             dex, caddy — its own standalone chart). Runs after
                             straiker-system-helm since frontend connects to that chart's
                             postgres/opensearch directly. More product-specific phases/charts
                             (Ascend, Defend, ...) will be added here later.

Notes:
  - If a phase preflight is not met, the installer marks that phase BLOCKED and exits cleanly.
  - Re-run the same command after fixing prerequisites.
  - straiker-system-helm always auto-fills clusterName (captured/auto-detected up
    front, regardless of --install-eks). eks.nodeRole is auto-filled from Terraform
    outputs when eks-cluster provisioned the cluster itself, or otherwise detected
    from an existing EC2NodeClass on a bring-your-own cluster; --values can still
    override it explicitly if neither applies or picks the wrong one.
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
      --install-eks)
        INSTALL_EKS=true
        INSTALL_EKS_EXPLICIT=true
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
      --aws-profile)
        AWS_PROFILE_OPT=${2:-}
        shift 2
        ;;
      --tf-prefix)
        TF_PREFIX=${2:-}
        shift 2
        ;;
      --cluster-name)
        CLUSTER_NAME=${2:-}
        shift 2
        ;;
      --namespace)
        INFRA_NAMESPACE=${2:-}
        shift 2
        ;;
      --repo-name)
        HELM_REPO_NAME=${2:-}
        shift 2
        ;;
      --repo-url)
        HELM_REPO_URL=${2:-}
        shift 2
        ;;
      --chart-version)
        CHART_VERSION=${2:-}
        shift 2
        ;;
      --values)
        VALUES_FILES+=("${2:-}")
        shift 2
        ;;
      --straiker-credential-file)
        STRAIKER_CREDENTIAL_FILE=${2:-}
        shift 2
        ;;
      --products)
        PRODUCTS_OPT=${2:-}
        shift 2
        ;;
      --timeout)
        HELM_TIMEOUT=${2:-}
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
  set_install_status "failed" "${message}"
  echo "ERROR: ${message}" >&2
  exit "${code}"
}

# ERR only fires on command failures under set -e — it does NOT fire on signals.
# If the session/connection dies mid-phase (e.g. a CloudShell session timing out
# mid `tofu apply`), this is what keeps the phase from being left at a stale
# "in_progress" that a naive re-run might treat as ambiguous.
on_interrupt() {
  local message="Interrupted in phase '${CURRENT_PHASE}' (signal received; the underlying tofu/helm command may have kept running server-side — verify directly before assuming nothing happened)."
  if [[ -n "${CURRENT_PHASE}" ]]; then
    set_phase_status "${CURRENT_PHASE}" "failed" "${message}"
  fi
  set_install_status "failed" "${message}"
  echo "ERROR: ${message}" >&2
  exit 130
}

mark_phase_blocked() {
  local message=$1
  set_phase_status "${CURRENT_PHASE}" "blocked" "${message}"
  set_install_status "blocked" "${message}"
  INSTALL_BLOCKED=true
  BLOCK_MESSAGE="${message}"
  log "Phase '${CURRENT_PHASE}' blocked: ${message}"
}

require_terraform_dir() {
  local dir=$1
  if [[ ! -d "${dir}" ]]; then
    mark_phase_blocked "Terraform config not found at '${dir}'. This requires a full clone of straiker-ai/onprem-installer (the installer bundle includes it automatically)."
    return 1
  fi
  return 0
}

# Copies just the .tf sources into the /tmp work dir, leaving .terraform/,
# backend.tf, terraform.auto.tfvars, and any state already there untouched —
# so re-running a phase doesn't re-download providers or lose local state.
sync_terraform_workdir() {
  local src=$1 dest=$2
  mkdir -p "${dest}"
  cp -f "${src}"/*.tf "${dest}/"
}

write_eks_backend_config() {
  local bucket_name=$1
  cat > "${EKS_DIR}/backend.tf" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
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

write_artifacts_backend_config() {
  local bucket_name=$1
  cat > "${ARTIFACTS_DIR}/backend.tf" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
terraform {
  backend "s3" {
    bucket       = "${bucket_name}"
    key          = "s6r-onprem/artifacts.tfstate"
    region       = "${AWS_REGION}"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
}

# Renders var.image_names as a tofu-var JSON array, e.g. ["a/b","c/d"].
write_eks_tfvars() {
  local az1 az2
  read -r az1 az2 _ <<< "$(aws ec2 describe-availability-zones \
    --region "${AWS_REGION}" \
    --filters Name=state,Values=available \
    --query 'AvailabilityZones[].ZoneName' \
    --output text)"

  if [[ -z "${az1:-}" || -z "${az2:-}" ]]; then
    mark_phase_blocked "Could not resolve two availability zones for region '${AWS_REGION}'."
    return
  fi

  cat > "${EKS_DIR}/terraform.auto.tfvars" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
region             = "${AWS_REGION}"
availability_zones = ["${az1}", "${az2}"]
cluster_name       = "${CLUSTER_NAME}"
EOF
  set_metadata "availability_zones" "${az1},${az2}"
}

resolve_bucket_name() {
  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  echo "${TF_PREFIX}-tfstate-${AWS_REGION}-${account_id}"
}

require_file_inputs() {
  local file
  for file in "$@"; do
    if [[ ! -f "${file}" ]]; then
      echo "ERROR: values file not found: ${file}" >&2
      exit 1
    fi
  done
}

ensure_k8s_ready_for_charts() {
  if kubectl cluster-info >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${INSTALL_EKS}" == false ]]; then
    echo "ERROR: Kubernetes/EKS is not reachable and --install-eks was not enabled." >&2
    echo "       Either provide a working cluster context or re-run with --install-eks." >&2
    exit 1
  fi
  mark_phase_blocked "Kubernetes API is not reachable yet. Re-run after cluster is ready."
  return 1
}

phase_eks_tfbe() {
  # Mandatory, not gated on --install-eks: this phase also owns (or will own)
  # the ECR mirror and models S3 bucket, which every install needs regardless
  # of whether we provision the EKS cluster itself.
  if [[ -z "${AWS_REGION}" ]]; then
    mark_phase_blocked "AWS region is required. Use --aws-region, AWS_REGION, or configure the AWS CLI."
    return
  fi

  require_command aws
  require_command tofu
  require_terraform_dir "${TFBE_SRC}" || return
  sync_terraform_workdir "${TFBE_SRC}" "${TFBE_DIR}"

  tofu -chdir="${TFBE_DIR}" init -upgrade -input=false

  # tfbe's state is local-only (bootstrapping the state bucket can't itself use
  # a remote backend), so a fresh run has no memory of a bucket a prior run
  # already created. Import it instead of letting apply fail on BucketAlreadyExists.
  local bucket_name
  bucket_name="$(resolve_bucket_name)"
  if aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
    log "Bucket '${bucket_name}' already exists — importing into Terraform state instead of recreating it."
    tofu -chdir="${TFBE_DIR}" import -var="region=${AWS_REGION}" -var="prefix=${TF_PREFIX}" \
      aws_s3_bucket.tfstate "${bucket_name}" 2>/dev/null || true
  fi

  tofu -chdir="${TFBE_DIR}" apply -var="region=${AWS_REGION}" -var="prefix=${TF_PREFIX}" -auto-approve -input=false

  bucket_name="$(tofu -chdir="${TFBE_DIR}" output -raw bucket_name)"
  set_metadata "aws_region" "${AWS_REGION}"
  set_metadata "tf_prefix" "${TF_PREFIX}"
  set_metadata "bootstrap_bucket" "${bucket_name}"
}

phase_eks_cluster() {
  if [[ "${INSTALL_EKS}" == false ]]; then
    log "Skipping EKS cluster provisioning; pass --install-eks to provision one (bring-your-own-cluster expected otherwise)."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--install-eks not set."
    return
  fi
  if [[ -z "${AWS_REGION}" ]]; then
    mark_phase_blocked "AWS region is required for EKS provisioning. Use --aws-region or AWS_REGION."
    return
  fi

  require_command aws
  require_command tofu
  require_command kubectl
  require_terraform_dir "${EKS_SRC}" || return
  sync_terraform_workdir "${EKS_SRC}" "${EKS_DIR}"

  local bucket_name
  bucket_name="$(get_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    bucket_name="$(resolve_bucket_name)"
  fi

  if ! aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
    mark_phase_blocked "Bootstrap bucket '${bucket_name}' not found. Run phase 'eks-tfbe' first."
    return
  fi

  write_eks_backend_config "${bucket_name}"
  write_eks_tfvars
  if [[ "${INSTALL_BLOCKED}" == true ]]; then
    return
  fi

  tofu -chdir="${EKS_DIR}" init -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${EKS_DIR}" apply -auto-approve -input=false

  local cluster_name cluster_endpoint node_role_arn queue_name
  cluster_name="$(tofu -chdir="${EKS_DIR}" output -raw cluster_name)"
  cluster_endpoint="$(tofu -chdir="${EKS_DIR}" output -raw cluster_endpoint)"
  node_role_arn="$(tofu -chdir="${EKS_DIR}" output -raw karpenter_node_role_arn)"
  queue_name="$(tofu -chdir="${EKS_DIR}" output -raw karpenter_queue_name)"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${cluster_name}" >/dev/null

  # terraform-aws-modules/eks's aws-ebs-csi-driver addon installs the CSI
  # driver but creates no StorageClass at all — charts/straiker-system's
  # opensearch.persistence.storageClass is "" (defers to a cluster default),
  # so without this, opensearch's PVC can never bind on a cluster we
  # provisioned ourselves. Only done here, not for bring-your-own clusters —
  # k8s-preflight checks for one there instead, rather than us unilaterally
  # creating/marking-default a StorageClass on infrastructure we don't own.
  log "Creating default StorageClass 'gp3' (ebs.csi.aws.com) for this cluster."
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
YAML

  set_metadata "cluster_name" "${cluster_name}"
  set_metadata "cluster_endpoint" "${cluster_endpoint}"
  set_metadata "karpenter_node_role_arn" "${node_role_arn}"
  set_metadata "karpenter_queue_name" "${queue_name}"
}

phase_karpenter() {
  if [[ "${INSTALL_EKS}" == false ]]; then
    log "Skipping Karpenter controller install; pass --install-eks to also install it (bring-your-own-cluster is expected to manage its own Karpenter, if any)."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--install-eks not set."
    return
  fi

  require_command helm
  require_command kubectl

  local cluster_name queue_name
  cluster_name="$(get_metadata "cluster_name")"
  queue_name="$(get_metadata "karpenter_queue_name")"

  if [[ -z "${cluster_name}" || -z "${queue_name}" ]]; then
    # eks-cluster may have completed under an older version of this installer
    # that didn't record karpenter_queue_name. Terraform's already-applied state
    # still has it — re-read the outputs directly (no apply needed) instead of
    # forcing a wasteful full re-run of eks-cluster.
    log "cluster_name/karpenter_queue_name missing from install state (likely completed under an older installer version) — reading directly from Terraform state instead."
    if [[ -z "${AWS_REGION}" ]]; then
      mark_phase_blocked "AWS region is required. Use --aws-region or AWS_REGION."
      return
    fi
    require_command aws
    require_command tofu
    require_terraform_dir "${EKS_SRC}" || return
    sync_terraform_workdir "${EKS_SRC}" "${EKS_DIR}"

    local bucket_name
    bucket_name="$(get_metadata "bootstrap_bucket")"
    [[ -n "${bucket_name}" ]] || bucket_name="$(resolve_bucket_name)"
    if ! aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
      mark_phase_blocked "Bootstrap bucket '${bucket_name}' not found. Run phase 'eks-tfbe' first."
      return
    fi

    write_eks_backend_config "${bucket_name}"
    tofu -chdir="${EKS_DIR}" init -upgrade -input=false -migrate-state -force-copy

    cluster_name="$(tofu -chdir="${EKS_DIR}" output -raw cluster_name 2>/dev/null || echo "")"
    queue_name="$(tofu -chdir="${EKS_DIR}" output -raw karpenter_queue_name 2>/dev/null || echo "")"
    if [[ -z "${cluster_name}" || -z "${queue_name}" ]]; then
      mark_phase_blocked "Could not read cluster_name/karpenter_queue_name from Terraform state either. Run phase 'eks-cluster' (add --rerun-phase if it's marked done) first."
      return
    fi
    set_metadata "cluster_name" "${cluster_name}"
    set_metadata "karpenter_queue_name" "${queue_name}"
  fi

  helm upgrade --install karpenter "oci://public.ecr.aws/karpenter/karpenter" \
    --version "${KARPENTER_VERSION}" \
    --namespace "${KARPENTER_NAMESPACE}" \
    --create-namespace \
    --set "settings.clusterName=${cluster_name}" \
    --set "settings.interruptionQueue=${queue_name}" \
    --set "controller.resources.requests.cpu=1" \
    --set "controller.resources.requests.memory=1Gi" \
    --set "controller.resources.limits.cpu=1" \
    --set "controller.resources.limits.memory=1Gi" \
    --wait --timeout "${HELM_TIMEOUT}"
}

# Mandatory, regardless of --install-eks: eks-cluster/karpenter installing (or
# being skipped for bring-your-own-cluster) doesn't by itself prove the cluster
# is actually usable. Without this gate, a bring-your-own-cluster install with
# no working Karpenter would sail through aws-artifacts/artifacts-sync (neither
# needs it) and only fail deep inside straiker-system-helm's chart render, via
# its NodePool templates' own `fail "Karpenter is not installed"` check — late
# and unclear compared to catching it here.
phase_k8s_preflight() {
  require_command kubectl

  if ! kubectl cluster-info >/dev/null 2>&1; then
    if [[ "${INSTALL_EKS}" == true ]]; then
      mark_phase_blocked "Kubernetes API not reachable even after eks-cluster ran. Check: aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}."
    else
      mark_phase_blocked "Kubernetes API not reachable. Point kubectl at your existing cluster (aws eks update-kubeconfig --region <region> --name <cluster>), or re-run with --install-eks to provision one."
    fi
    return
  fi

  # A StorageClass — required for opensearch's PVC to ever bind (its
  # persistence.storageClass value is "", i.e. "use the cluster default").
  # Checked regardless of --install-eks: our own eks-cluster phase creates a
  # default one, but this is what actually catches it here instead of
  # straiker-system-helm silently hanging for its full --wait timeout on a pod
  # that can never schedule. Prefer a real default; if there isn't one but
  # exactly one StorageClass exists at all, use it explicitly (persisted for
  # phase_straiker_system_helm to --set) rather than making the customer go
  # mark something default by hand. Only genuinely block when it's ambiguous
  # (multiple classes, none default) or there's nothing to fall back to.
  # resolved_storage_class always ends up with a real name (used unconditionally
  # for postgres, which has no "cluster default" fallback of its own —
  # postgres.yaml's `required` fails loudly without one). fallback_storage_class
  # is only set when there's no true cluster default, since opensearch is
  # happy to rely on that mechanism directly rather than being told explicitly.
  local default_sc
  default_sc="$(kubectl get storageclass \
    -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${default_sc}" ]]; then
    log "Default StorageClass '${default_sc}' found."
    set_metadata "fallback_storage_class" ""
    set_metadata "resolved_storage_class" "${default_sc}"
  else
    local -a all_scs=()
    local all_sc_raw
    all_sc_raw="$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    read -r -a all_scs <<< "${all_sc_raw}"

    if [[ "${#all_scs[@]}" -eq 0 ]]; then
      mark_phase_blocked "No StorageClass found on this cluster at all. opensearch's/postgres's PersistentVolumeClaims need one to bind. Create one (e.g. an EBS-backed gp3 StorageClass), or override opensearch.persistence.storageClass/postgres.storage.storageClassName via --values."
      return
    elif [[ "${#all_scs[@]}" -eq 1 ]]; then
      log "No default StorageClass, but exactly one exists ('${all_scs[0]}') — will use it."
      set_metadata "fallback_storage_class" "${all_scs[0]}"
      set_metadata "resolved_storage_class" "${all_scs[0]}"
    else
      mark_phase_blocked "No default StorageClass, and multiple exist (${all_scs[*]}) with no way to guess which to use. Mark one default (kubectl annotate storageclass <name> storageclass.kubernetes.io/is-default-class=true --overwrite), or override opensearch.persistence.storageClass/postgres.storage.storageClassName via --values."
      return
    fi
  fi

  if [[ "${INSTALL_EKS}" == true ]]; then
    # Our own eks-cluster + karpenter phases already proved the rest works.
    return
  fi

  if ! kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    mark_phase_blocked "Karpenter is not installed on this cluster (CRD 'nodepools.karpenter.sh' not found). straiker-system's NodePool templates require it. Install Karpenter first (https://karpenter.sh/docs/getting-started/), or re-run with --install-eks to have this installer manage it."
    return
  fi

  # Namespace isn't fixed — mirrors the same lookup a customer's own Karpenter
  # install might use (dedicated "karpenter" ns is the common case, but not
  # guaranteed), falling back to the "karpenter" literal if nothing is found.
  local karpenter_ns pod_count crashing
  karpenter_ns="$(kubectl get pods -A -l app.kubernetes.io/name=karpenter \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  [[ -n "${karpenter_ns}" ]] || karpenter_ns="karpenter"

  pod_count="$(kubectl get pods -n "${karpenter_ns}" -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${pod_count}" -eq 0 ]]; then
    mark_phase_blocked "Karpenter CRDs are present, but no karpenter controller pods were found (checked namespace '${karpenter_ns}'). Check your Karpenter install, or re-run with --install-eks to have this installer manage it."
    return
  fi

  crashing="$(kubectl get pods -n "${karpenter_ns}" -l app.kubernetes.io/name=karpenter \
    -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c CrashLoopBackOff || true)"
  if [[ "${crashing}" -gt 0 ]]; then
    mark_phase_blocked "Karpenter controller pod(s) in namespace '${karpenter_ns}' are crash-looping. Check: kubectl logs -n ${karpenter_ns} -l app.kubernetes.io/name=karpenter"
    return
  fi

  log "Karpenter looks healthy in namespace '${karpenter_ns}' (CRDs present, ${pod_count} controller pod(s) running)."
}

phase_aws_artifacts() {
  # Mandatory like eks-tfbe: the ECR mirror + models bucket are needed regardless
  # of whether we provisioned the cluster or the customer brought their own.
  if [[ -z "${AWS_REGION}" ]]; then
    mark_phase_blocked "AWS region is required. Use --aws-region, AWS_REGION, or configure the AWS CLI."
    return
  fi

  require_command aws
  require_command tofu
  require_terraform_dir "${ARTIFACTS_SRC}" || return
  sync_terraform_workdir "${ARTIFACTS_SRC}" "${ARTIFACTS_DIR}"

  local bucket_name
  bucket_name="$(get_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    bucket_name="$(resolve_bucket_name)"
  fi
  if ! aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
    mark_phase_blocked "Bootstrap bucket '${bucket_name}' not found. Run phase 'eks-tfbe' first."
    return
  fi

  # The pod identity association below needs the cluster to already exist in AWS
  # (ours via eks-cluster, or the customer's own) — fail with clear guidance
  # rather than a raw AWS API error from deep inside tofu apply.
  if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    mark_phase_blocked "EKS cluster '${CLUSTER_NAME}' not found in ${AWS_REGION}. Run with --install-eks to provision one, or pass --cluster-name matching your existing cluster."
    return
  fi

  write_artifacts_backend_config "${bucket_name}"

  tofu -chdir="${ARTIFACTS_DIR}" init -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${ARTIFACTS_DIR}" apply -auto-approve -input=false \
    -var="region=${AWS_REGION}" \
    -var="prefix=${TF_PREFIX}" \
    -var="cluster_name=${CLUSTER_NAME}"

  local models_bucket ecr_registry hauler_role_arn
  models_bucket="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw models_bucket_name)"
  ecr_registry="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw ecr_registry)"
  hauler_role_arn="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw hauler_role_arn)"

  set_metadata "models_bucket" "${models_bucket}"
  set_metadata "ecr_registry" "${ecr_registry}"
  set_metadata "hauler_role_arn" "${hauler_role_arn}"
}

# Parses the SKU out of the credential's client_email, which Straiker provisions
# in a fixed "cust-<sku>-..." format (e.g. "cust-pro-foo-bar@...iam.gserviceaccount.com"
# -> "pro"). Echoes the sku, or "base" if the file/field is missing or doesn't match
# — a safe default, since sku: "base" images in charts/straiker-artifact are always
# attempted regardless, and this only widens or narrows what else gets attempted.
detect_customer_sku() {
  local email sku
  email="$(python3 - "${STRAIKER_CREDENTIAL_FILE}" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f).get("client_email", ""))
PY
  )"
  if [[ "${email}" =~ ^cust-([a-z0-9]+)- ]]; then
    sku="${BASH_REMATCH[1]}"
  else
    sku="base"
  fi
  echo "${sku}"
}

# Reports one artifact-sync Job's status. Echoes "complete", "failed", or
# "running" and logs a human-readable line; never touches the Job itself — it
# was already created (or not) by this phase's helm install below.
check_artifact_job() {
  local name=$1
  if ! kubectl get job "${name}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    log "Job '${name}': not found yet."
    echo "running"
    return
  fi

  local complete failed
  complete="$(kubectl get job "${name}" -n "${INFRA_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")"
  if [[ "${complete}" == "True" ]]; then
    log "Job '${name}': complete."
    echo "complete"
    return
  fi

  failed="$(kubectl get job "${name}" -n "${INFRA_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")"
  if [[ "${failed}" == "True" ]]; then
    log "Job '${name}': FAILED (exhausted retries). Check: kubectl logs job/${name} -n ${INFRA_NAMESPACE}"
    echo "failed"
    return
  fi

  log "Job '${name}': still running. Watch live: kubectl logs -f job/${name} -n ${INFRA_NAMESPACE}"
  echo "running"
}

# Installs the straiker-artifact chart (mirror + model-sync Jobs) and blocks
# the installer here until both report complete — straiker-system-helm's workloads
# pull images through the ECR mirror these Jobs populate, so it must not run first.
phase_artifacts_sync() {
  require_command helm
  require_command kubectl

  # This phase gets re-invoked every time the installer is re-run while it's
  # blocked (that's not "already done" — Jobs can run for hours), but re-running
  # the setup below on every one of those check-ins would re-prompt for the
  # credential and `helm upgrade --install` again, bumping the release revision
  # and disturbing already-running Jobs for no reason. So: once the release
  # exists, later invocations skip straight to polling. --rerun-phase forces a
  # real redo (e.g. to fix a bad credential).
  if [[ "${FORCE_RERUN}" != true ]] && helm status "${ARTIFACT_RELEASE}" --namespace "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    log "Release '${ARTIFACT_RELEASE}' already installed — checking progress (use --rerun-phase to force reinstall)."
  else
    require_file_inputs "${STRAIKER_CREDENTIAL_FILE}"
    ensure_k8s_ready_for_charts || return

    local ecr_registry models_bucket ecr_registry_prefixed
    ecr_registry="$(get_metadata "ecr_registry")"
    models_bucket="$(get_metadata "models_bucket")"
    if [[ -z "${ecr_registry}" || -z "${models_bucket}" ]]; then
      mark_phase_blocked "Missing ecr_registry/models_bucket from install state. Run phase 'aws-artifacts' first."
      return
    fi
    # ECR repos live under "<registry>/<prefix>/..." (see terraform/aws/artifacts),
    # so the mirror destination and the chart's pull registry must both include
    # the prefix — "<registry>/<prefix>" is itself a valid registry value.
    ecr_registry_prefixed="${ecr_registry}/${TF_PREFIX}"

    helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
    helm repo update "${HELM_REPO_NAME}" >/dev/null

    kubectl create namespace "${INFRA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    kubectl create secret generic "${STRAIKER_CREDENTIAL_SECRET_NAME}" \
      --namespace "${INFRA_NAMESPACE}" \
      --from-file="key.json=${STRAIKER_CREDENTIAL_FILE}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    local customer_sku
    customer_sku="$(detect_customer_sku)"
    log "Detected customer sku '${customer_sku}' from credential (drives which images are attempted)."

    # Job.spec.template is immutable in Kubernetes — if a Job from a previous
    # attempt already exists (e.g. its pod got stuck Pending on a taint before
    # this chart had the right toleration), `helm upgrade` cannot patch it in
    # place; it would just silently leave the stale Job/pod as-is. Delete first
    # so the upgrade below always creates a fresh Job from the current template.
    kubectl delete job straiker-artifact-image-mirror straiker-artifact-model-sync \
      --namespace "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null

    # Not --wait: these Jobs can run for hours (large model syncs) and must not
    # block this command synchronously. set -e + the ERR trap already mark this
    # phase "failed" and abort if the helm command itself errors; the polling
    # below separately catches the Jobs themselves failing after being created.
    helm upgrade --install "${ARTIFACT_RELEASE}" "${HELM_REPO_NAME}/${ARTIFACT_CHART_NAME}" \
      --namespace "${INFRA_NAMESPACE}" \
      --create-namespace \
      --set "straikerCredentialSecretName=${STRAIKER_CREDENTIAL_SECRET_NAME}" \
      --set "ecrRegistry=${ecr_registry_prefixed}" \
      --set "modelsBucket=${models_bucket}" \
      --set "customerSku=${customer_sku}" \
      --set "imageMirror.enabled=true" \
      --set "modelSync.enabled=true"
  fi

  local pending=false failed=false status

  status="$(check_artifact_job "straiker-artifact-image-mirror")"
  [[ "${status}" == "failed" ]] && failed=true
  [[ "${status}" != "complete" ]] && pending=true

  status="$(check_artifact_job "straiker-artifact-model-sync")"
  [[ "${status}" == "failed" ]] && failed=true
  [[ "${status}" != "complete" ]] && pending=true

  if [[ "${failed}" == true ]]; then
    mark_phase_blocked "Artifact sync FAILED (a Job exhausted its retries) — see the kubectl logs hint above. straiker-system-helm will not run until this is resolved. Fix the underlying issue, delete the failed Job(s) in namespace '${INFRA_NAMESPACE}', then re-run --phase artifacts-sync."
    return
  fi

  if [[ "${pending}" == true ]]; then
    mark_phase_blocked "Artifact sync still running in-cluster (it survives this command exiting). straiker-system-helm will not run until this completes. Re-run --phase artifacts-sync any time to check again."
    return
  fi
}

# Helm refuses to manage a resource that already exists but wasn't created by
# it (missing meta.helm.sh/release-* ownership metadata) — a real scenario on
# bring-your-own clusters that already have overlapping cluster-scoped
# resources (e.g. an existing NVIDIA GPU Operator's RuntimeClass named
# "nvidia", the chart's own default name). Annotating/labeling it for adoption
# is Helm's own documented fix; do it proactively here so this doesn't fail
# the install every time instead of once. namespace="" for cluster-scoped kinds.
adopt_existing_resource() {
  local kind=$1 name=$2 namespace=$3
  local -a ns_args=()
  [[ -n "${namespace}" ]] && ns_args=(--namespace "${namespace}")

  if ! kubectl get "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} >/dev/null 2>&1; then
    return 0
  fi

  local owner
  owner="$(kubectl get "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} \
    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
  [[ "${owner}" == "${INFRA_RELEASE}" ]] && return 0

  log "Adopting existing ${kind} '${name}' into release '${INFRA_RELEASE}' (it already existed, unmanaged, on this cluster)."
  kubectl annotate "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} \
    "meta.helm.sh/release-name=${INFRA_RELEASE}" \
    "meta.helm.sh/release-namespace=${INFRA_NAMESPACE}" --overwrite >/dev/null
  kubectl label "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} \
    "app.kubernetes.io/managed-by=Helm" --overwrite >/dev/null
}

phase_straiker_system_helm() {
  require_command helm
  require_command kubectl

  # Known collision: charts/straiker-system's default nvidia.runtimeClass.name
  # ("nvidia") often already exists on clusters with GPU support pre-configured
  # (e.g. NVIDIA GPU Operator). Only covers that default name — a customer
  # overriding it via --values to something else would need the same manual
  # `kubectl annotate`/`kubectl label` fix for their custom name.
  adopt_existing_resource "runtimeclass" "nvidia" ""

  require_file_inputs "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"
  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  local cmd=(
    helm upgrade --install "${INFRA_RELEASE}" "${HELM_REPO_NAME}/${INFRA_CHART_NAME}"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --wait
    --timeout "${HELM_TIMEOUT}"
  )

  if [[ -n "${CHART_VERSION}" ]]; then
    cmd+=(--version "${CHART_VERSION}")
  fi

  # clusterName is always known by this point — captured/auto-detected in
  # capture_install_config regardless of --install-eks — so it's always safe
  # to fill in, not just for our own provisioned clusters. eks.nodeRole is
  # different: it only exists as a Terraform output for clusters we
  # provisioned ourselves, so bring-your-own-cluster still needs it via
  # --values (see show_plan's note).
  log "Auto-filling clusterName (${CLUSTER_NAME})."
  cmd+=(--set "clusterName=${CLUSTER_NAME}")

  local tf_node_role_arn
  tf_node_role_arn="$(get_metadata "karpenter_node_role_arn")"
  if [[ -n "${tf_node_role_arn}" ]]; then
    log "Auto-filling eks.nodeRole from this installer's Terraform outputs."
    cmd+=(--set "eks.nodeRole=${tf_node_role_arn}")
  else
    # Bring-your-own-cluster: no Terraform-managed node role exists. k8s-preflight
    # already confirmed Karpenter is running, so reuse whatever node role its
    # existing EC2NodeClass(es) already use rather than making the customer look
    # it up. A later --values override (applied after every --set here) still wins
    # if the customer explicitly sets eks.nodeRole themselves.
    local detected_node_role
    detected_node_role="$(kubectl get ec2nodeclass -o jsonpath='{.items[0].spec.role}' 2>/dev/null || true)"
    if [[ -n "${detected_node_role}" ]]; then
      log "Auto-detected eks.nodeRole from an existing EC2NodeClass: ${detected_node_role}"
      cmd+=(--set "eks.nodeRole=${detected_node_role}")
    fi
  fi

  # aws-artifacts (mandatory, runs before this) always provisions the ECR mirror,
  # and artifacts-sync (also mandatory, runs before this) always blocks until it's
  # populated — so it's always safe to point pulls at it once it exists.
  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  if [[ -n "${ecr_registry}" ]]; then
    local ecr_registry_prefixed="${ecr_registry}/${TF_PREFIX}"
    log "Pointing global.dockerRegistry at the ECR mirror (${ecr_registry_prefixed})."
    cmd+=(--set "global.dockerRegistry=${ecr_registry_prefixed}")
  fi

  # k8s-preflight sets this when there's no default StorageClass but exactly
  # one exists — opensearch.persistence.storageClass is "" by default (relies
  # on a real cluster default), so that single StorageClass needs to be named
  # explicitly here instead.
  local fallback_storage_class
  fallback_storage_class="$(get_metadata "fallback_storage_class")"
  if [[ -n "${fallback_storage_class}" ]]; then
    log "Using '${fallback_storage_class}' for opensearch.persistence.storageClass (no cluster default StorageClass)."
    cmd+=(--set "opensearch.persistence.storageClass=${fallback_storage_class}")
  fi

  # postgres has no "use the cluster default" mechanism of its own —
  # postgres.storage.storageClassName is required() and fails loudly if unset —
  # so unlike opensearch above, this is always passed explicitly.
  local resolved_storage_class
  resolved_storage_class="$(get_metadata "resolved_storage_class")"
  if [[ -n "${resolved_storage_class}" ]]; then
    cmd+=(--set "postgres.storage.storageClassName=${resolved_storage_class}")
  fi

  # Product -> NodePool mapping: Ascend uses karpenter.iris, Defend uses
  # karpenter.argus. Both are non-null (enabled) by default in the chart's own
  # values.yaml, so an unselected product must be explicitly nulled to skip
  # provisioning its NodePool. Shared system services (opensearch/postgres/redis)
  # aren't gated by product selection at all.
  if [[ ",${PRODUCTS_OPT}," != *",ascend,"* ]]; then
    cmd+=(--set "karpenter.iris=null")
  fi
  if [[ ",${PRODUCTS_OPT}," != *",defend,"* ]]; then
    cmd+=(--set "karpenter.argus=null")
  fi

  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  "${cmd[@]}"
}

# Application layer — frontend/bifrost/glauth/dex/caddy (charts/straiker-core,
# a standalone chart). Runs after straiker-system-helm since frontend connects
# to that chart's postgres/opensearch directly (see straiker-core's
# global.infraNamespace default).
phase_straiker_core_helm() {
  require_command helm
  require_command kubectl

  require_file_inputs "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"
  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  local cmd=(
    helm upgrade --install "${APP_RELEASE}" "${HELM_REPO_NAME}/${APP_CHART_NAME}"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --wait
    --timeout "${HELM_TIMEOUT}"
  )

  if [[ -n "${CHART_VERSION}" ]]; then
    cmd+=(--version "${CHART_VERSION}")
  fi

  # aws-artifacts/artifacts-sync (both mandatory, run earlier) always provision
  # and populate the ECR mirror — bifrost/frontend/glauth/dex/caddy all need
  # this, same as straiker-system-helm. straiker-core is a standalone chart
  # (not a subchart), so these are just its own top-level values — no
  # "straiker-core." prefix needed.
  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  if [[ -n "${ecr_registry}" ]]; then
    local ecr_registry_prefixed="${ecr_registry}/${TF_PREFIX}"
    log "Pointing global.dockerRegistry at the ECR mirror (${ecr_registry_prefixed})."
    cmd+=(--set "global.dockerRegistry=${ecr_registry_prefixed}")
  fi

  # Matches charts/straiker-system's own namespace (both default to
  # INFRA_NAMESPACE) — override both together if that chart is ever installed
  # somewhere else.
  cmd+=(--set "global.infraNamespace=${INFRA_NAMESPACE}")

  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  "${cmd[@]}"

  # Read the actual deployed domain back from Caddy's own ConfigMap rather
  # than re-deriving it — robust regardless of how appDomain was set (chart
  # default, --set, or a customer values file).
  local app_domain
  app_domain="$(kubectl -n "${INFRA_NAMESPACE}" get configmap caddy-config -o jsonpath='{.data.Caddyfile}' 2>/dev/null | grep -o 'app\.[^ {]*' | head -1 || true)"
  if [[ -n "${app_domain}" ]]; then
    log ""
    log "Straiker is installed. To reach it from your machine:"
    log "  1. echo '127.0.0.1 ${app_domain}' | sudo tee -a /etc/hosts"
    log "  2. sudo kubectl -n ${INFRA_NAMESPACE} port-forward svc/caddy-service 443:443"
    log "  3. open https://${app_domain}/ (a self-signed cert warning is expected)"
  fi
}

# Prompts on /dev/tty (never stdin — this must work under `curl | bash`, which
# consumes stdin as the script source) with the prompt text written directly to
# /dev/tty rather than via `read -p` — `read -p`'s prompt goes to stderr, and a
# bare `2>/dev/null` guard (to turn "no such device" into a clean message
# instead of a raw OS error) would silently swallow it too. Echoes the answer,
# or nothing if there's no tty or the user left it blank.
prompt_line() {
  local prompt=$1
  if [[ ! -e /dev/tty ]] || ! printf '%s' "${prompt}" 2>/dev/null > /dev/tty; then
    return 1
  fi
  local typed=""
  read -r typed < /dev/tty || true
  echo "${typed}"
}

# Captures the one-time, install-defining choices (AWS profile/region, whether
# to provision EKS or use an existing cluster) once and persists them — later
# invocations (retries, --rerun-phase, just continuing) reuse them instead of
# re-asking, but an explicit flag on any given run still overrides AND
# re-persists, so a correction (e.g. a rotated profile name) sticks going
# forward rather than needing to be repeated on every future invocation.
# Always announces the effective values in use, so a stale captured value is
# visible rather than a silent surprise.
# Validates/normalizes a --products value (flag or interactive answer) into a
# canonical, comma-separated list. Accepts either the numbers shown in the
# prompt or product names, case-insensitive, comma- or space-separated.
# "discover" is recognized but has no chart component yet (pathfinder isn't
# built) — it's dropped with a warning rather than rejected outright, since
# picking it isn't a mistake, just early. Anything else is a hard error (typo
# protection) rather than being silently ignored.
normalize_products() {
  local raw=$1
  local -a tokens=() result=()
  local token token_lower
  IFS=', ' read -r -a tokens <<< "${raw}"
  for token in ${tokens[@]+"${tokens[@]}"}; do
    [[ -z "${token}" ]] && continue
    token_lower="$(printf '%s' "${token}" | tr '[:upper:]' '[:lower:]')"
    case "${token_lower}" in
      1|ascend) result+=("ascend") ;;
      2|defend) result+=("defend") ;;
      3|discover|pathfinder)
        log "Discover (pathfinder) isn't available yet — skipping it. It'll be selectable once support is added."
        ;;
      *)
        echo "ERROR: Unknown product '${token}'. Valid choices: ascend, defend (discover is coming soon)." >&2
        exit 1
        ;;
    esac
  done
  [[ "${#result[@]}" -eq 0 ]] && return 0
  printf '%s\n' "${result[@]}" | sort -u | paste -sd, -
}

capture_install_config() {
  if [[ "$(get_metadata "config_captured")" != "true" ]]; then
    cat >&2 <<'EOF'

 ____ _____ ____      _    ___ _  _______ ____
/ ___|_   _|  _ \    / \  |_ _| |/ / ____|  _ \
\___ \ | | | |_) |  / _ \  | || ' /|  _| | |_) |
 ___) || | |  _ <  / ___ \ | || . \| |___|  _ <
|____/ |_| |_| \_\/_/   \_\___|_|\_\_____|_| \_\

Let's set up this install. A few questions up front — each is saved as soon
as it's answered, so if you stop partway (e.g. don't have everything ready
yet), re-running only asks what's still missing. Delete
~/.straiker/install.json to start over from scratch.

EOF
  fi

  # AWS profile — optional; blank is a valid, deliberate answer (use the
  # default profile/credential chain), so "aws_profile_set" tracks whether
  # it's been asked at all, separately from whether the value itself is empty.
  if [[ -z "${AWS_PROFILE_OPT}" ]]; then
    if [[ "$(get_metadata "aws_profile_set")" == "true" ]]; then
      AWS_PROFILE_OPT="$(get_metadata "aws_profile")"
    else
      AWS_PROFILE_OPT="$(prompt_line 'AWS profile to use (leave blank for the default profile/credential chain): ' || true)"
    fi
  fi
  [[ -n "${AWS_PROFILE_OPT}" ]] && export AWS_PROFILE="${AWS_PROFILE_OPT}"
  set_metadata "aws_profile" "${AWS_PROFILE_OPT}"
  set_metadata "aws_profile_set" "true"

  # AWS region — mandatory, so unlike profile above, "still empty" always
  # means "still needs resolving" and doubles as its own tracking.
  [[ -z "${AWS_REGION}" ]] && AWS_REGION="$(get_metadata "aws_region")"
  resolve_aws_region
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="$(prompt_line 'AWS region (required): ' || true)"
  fi
  if [[ -z "${AWS_REGION}" ]]; then
    echo "ERROR: AWS region is required. Use --aws-region, AWS_REGION, or configure the AWS CLI." >&2
    exit 1
  fi
  set_metadata "aws_region" "${AWS_REGION}"

  # Install mode — false is both the default and a valid deliberate answer
  # ("use an existing cluster"), so it needs the same "_set" tracking as
  # profile above rather than relying on its own truthiness.
  if [[ "${INSTALL_EKS_EXPLICIT}" != true ]]; then
    if [[ "$(get_metadata "install_eks_set")" == "true" ]]; then
      [[ "$(get_metadata "install_eks")" == "true" ]] && INSTALL_EKS=true
    else
      local mode
      mode="$(prompt_line 'Provision a new EKS cluster, or use an existing one? [new/existing] (default: existing): ' || true)"
      [[ "${mode}" == "new" ]] && INSTALL_EKS=true
    fi
  fi
  set_metadata "install_eks" "${INSTALL_EKS}"
  set_metadata "install_eks_set" "true"

  # Products — mandatory, at least one; "still empty" doubles as "still needs
  # resolving," same as region above.
  [[ -z "${PRODUCTS_OPT}" ]] && PRODUCTS_OPT="$(get_metadata "products")"
  if [[ -z "${PRODUCTS_OPT}" ]]; then
    cat >&2 <<'EOF'

Which Straiker products should this install provision infrastructure for?
Select at least one.
  1) Ascend
  2) Defend
  3) Discover (coming soon — not yet available)
Shared system services (OpenSearch, Postgres, Redis) are installed either way.
EOF
    PRODUCTS_OPT="$(prompt_line 'Products to install, comma-separated (required, e.g. "1,2" or "ascend,defend"): ' || true)"
  fi
  # Normalize unconditionally, regardless of source (flag, persisted value, or
  # the prompt above) — every path must go through the same validation.
  PRODUCTS_OPT="$(normalize_products "${PRODUCTS_OPT}")"
  if [[ -z "${PRODUCTS_OPT}" ]]; then
    echo "ERROR: At least one product is required. Use --products ascend,defend (or select one interactively)." >&2
    exit 1
  fi
  set_metadata "products" "${PRODUCTS_OPT}"

  # Cluster name — resolved via flag/persisted/kubectl-context-auto-detect/
  # default; never persisted blank.
  [[ -z "${CLUSTER_NAME}" ]] && CLUSTER_NAME="$(get_metadata "cluster_name")"
  resolve_cluster_name
  set_metadata "cluster_name" "${CLUSTER_NAME}"

  # Namespace shared by every Straiker chart — resolved via flag/persisted/
  # prompt, defaulting to "straiker" if left blank; never persisted blank.
  [[ -z "${INFRA_NAMESPACE}" ]] && INFRA_NAMESPACE="$(get_metadata "namespace")"
  if [[ -z "${INFRA_NAMESPACE}" ]]; then
    INFRA_NAMESPACE="$(prompt_line 'Kubernetes namespace for all Straiker charts (default: straiker): ' || true)"
  fi
  [[ -z "${INFRA_NAMESPACE}" ]] && INFRA_NAMESPACE="straiker"
  set_metadata "namespace" "${INFRA_NAMESPACE}"

  # Credential file — mandatory. Only the path is stored, never the
  # credential's contents; and a stored path isn't trusted blindly since it
  # may point under a volatile dir (e.g. /tmp in a recycled CloudShell
  # session) that no longer exists.
  if [[ -z "${STRAIKER_CREDENTIAL_FILE}" ]]; then
    local remembered_cred
    remembered_cred="$(get_metadata "straiker_credential_file")"
    if [[ -n "${remembered_cred}" && -f "${remembered_cred}" ]]; then
      STRAIKER_CREDENTIAL_FILE="${remembered_cred}"
    fi
  fi
  if [[ -z "${STRAIKER_CREDENTIAL_FILE}" ]]; then
    cat >&2 <<'EOF'

Straiker provides a per-customer JSON credential file (contact your Straiker
rep if you don't have it). Save it locally and provide its path below.
EOF
    local typed_cred
    typed_cred="$(prompt_line 'Path to the Straiker credential JSON file (required): ' || true)"
    if [[ -z "${typed_cred}" ]]; then
      echo "ERROR: A Straiker credential file path is required (--straiker-credential-file <path>)." >&2
      exit 1
    fi
    if [[ ! -f "${typed_cred}" ]]; then
      echo "ERROR: No file found at '${typed_cred}'. Check the path and try again." >&2
      exit 1
    fi
    STRAIKER_CREDENTIAL_FILE="${typed_cred}"
  fi
  set_metadata "straiker_credential_file" "${STRAIKER_CREDENTIAL_FILE}"

  set_metadata "config_captured" "true"

  log "Config in use: aws_profile=${AWS_PROFILE_OPT:-<default>} aws_region=${AWS_REGION} install_eks=${INSTALL_EKS} cluster_name=${CLUSTER_NAME} namespace=${INFRA_NAMESPACE} products=${PRODUCTS_OPT:-<none>} straiker_credential_file=${STRAIKER_CREDENTIAL_FILE}"
}

require_resource_ack() {
  if [[ "$(get_metadata "resource_ack")" == "true" ]]; then
    return
  fi

  if [[ "${AUTO_YES}" == true ]]; then
    set_metadata "resource_ack" "true"
    return
  fi

  cat >&2 <<EOF

This installer will create the following resources in your AWS account:
  - An S3 bucket for Terraform state, prefixed 's6r-' (e.g. s6r-onprem-tfstate-<region>-<account-id>)
  - If run with --install-eks: a full EKS stack under the 's6r-onprem' name (VPC, EKS
    cluster, managed node group, Karpenter IAM roles + SQS queue, networking)
  - In a future update: mirrored container images pushed to ECR repositories, and
    model artifacts uploaded to an S3 bucket

This acknowledgement is recorded once in ~/.straiker/install.json and won't be asked again.

Type 'straiker' and press Enter to accept and continue.
EOF

  local typed
  if ! typed="$(prompt_line '> ')"; then
    echo "ERROR: No interactive terminal available to confirm resource creation. Re-run with --yes if you're sure." >&2
    exit 1
  fi
  if [[ "${typed}" != "straiker" ]]; then
    echo "ERROR: Acknowledgement not confirmed; aborting." >&2
    exit 1
  fi
  set_metadata "resource_ack" "true"
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
    eks-tfbe) phase_eks_tfbe ;;
    eks-cluster) phase_eks_cluster ;;
    karpenter) phase_karpenter ;;
    k8s-preflight) phase_k8s_preflight ;;
    aws-artifacts) phase_aws_artifacts ;;
    artifacts-sync) phase_artifacts_sync ;;
    straiker-system-helm) phase_straiker_system_helm ;;
    straiker-core-helm) phase_straiker_core_helm ;;
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
  if [[ -n "${AWS_PROFILE_OPT}" ]]; then
    export AWS_PROFILE="${AWS_PROFILE_OPT}"
  fi
  resolve_aws_region
  ensure_state_file

  if [[ "${PLAN_ONLY}" == true ]]; then
    show_plan
    exit 0
  fi

  if [[ "${STATUS_ONLY}" == true ]]; then
    show_state
    exit 0
  fi

  capture_install_config
  require_resource_ack
  build_phase_list
  set_install_status "in_progress" "Installer started."
  set_metadata "install_eks" "${INSTALL_EKS}"
  set_metadata "aws_region" "${AWS_REGION}"
  set_metadata "installer_bundle_version" "${INSTALLER_BUNDLE_VERSION}"
  set_metadata "installer_bundle_home" "${INSTALLER_BUNDLE_HOME}"
  if [[ -n "${INSTALLER_BUNDLE_URL}" ]]; then
    set_metadata "installer_bundle_url" "${INSTALLER_BUNDLE_URL}"
  fi

  local phase
  for phase in "${RUN_PHASES[@]}"; do
    run_phase "${phase}"
    if [[ "${INSTALL_BLOCKED}" == true ]]; then
      log "Installer paused: ${BLOCK_MESSAGE}"
      log "Fix prerequisites and rerun the installer."
      exit 0
    fi
  done

  set_install_status "done" "Installer completed."
  log "Install completed successfully."
  log "State file: ${STATE_FILE}"
}

main "$@"
