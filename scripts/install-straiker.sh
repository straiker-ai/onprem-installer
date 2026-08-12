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
INFRA_NAMESPACE="straiker-system"
INFRA_CHART_NAME="straiker-system"
# Installed (into the same INFRA_NAMESPACE as straiker-system) and polled to
# completion in phase_artifacts_sync, before straiker-system-helm — that chart's
# workloads pull images through the ECR mirror this chart populates.
ARTIFACT_RELEASE="straiker-artifact"
ARTIFACT_CHART_NAME="straiker-artifact"
# Must match charts/straiker-artifact's default straikerCredentialSecretName.
STRAIKER_CREDENTIAL_SECRET_NAME="straiker-credential"

AWS_REGION="${AWS_REGION:-}"
TF_PREFIX="s6r-onprem"
CLUSTER_NAME="s6r-onprem"
INSTALL_EKS=false
AUTO_YES=false
PLAN_ONLY=false
STATUS_ONLY=false
FORCE_RERUN=false

SELECT_PHASE=""
START_PHASE=""
CHART_VERSION=""
HELM_TIMEOUT="20m"
STRAIKER_CREDENTIAL_FILE=""

declare -a VALUES_FILES=()
declare -a ALL_PHASES=("eks-tfbe" "eks-cluster" "karpenter" "aws-artifacts" "artifacts-sync" "straiker-system-helm")
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
  --tf-prefix <prefix>            Prefix for the Terraform state bucket (default: s6r-onprem).
  --cluster-name <name>           EKS cluster name (default: s6r-onprem).
  --repo-name <name>              Helm repo name (default: straiker).
  --repo-url <url>                Helm repo URL (default: public dist repo).
  --chart-version <version>       Optional straiker-system chart version.
  --values <file>                 Values file for the straiker-system release (repeatable).
  --straiker-credential-file <path>
                                   Per-customer credentials file (from Straiker) for the
                                   artifact-mirroring Jobs to read source images/models. Loaded
                                   into a K8s Secret. Required — if omitted, you'll be prompted
                                   for it interactively when this phase runs.
  --timeout <duration>            Helm wait timeout (default: 20m).
  -h, --help                      Show this help.
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
  4) aws-artifacts        - create the ECR image mirror + models S3 bucket + hauler IAM role
                             (EKS Pod Identity). Always runs; needs a cluster to already exist
                             (ours via eks-cluster, or the customer's own via --cluster-name).
  5) artifacts-sync       - install/upgrade release 'straiker-artifact' (its own chart), which
                             creates the K8s Secret and runs the in-cluster image-mirror/model-sync
                             Jobs (plain resources, not Helm hooks — they can run for hours without
                             blocking this command). --straiker-credential-file is required; you'll
                             be prompted for it interactively if omitted. Blocks the installer here
                             until both Jobs report complete — re-run --phase artifacts-sync any
                             time to check again — since straiker-system-helm's workloads pull
                             images through the ECR mirror these Jobs populate.
  6) straiker-system-helm - add the public straiker Helm repo and install/upgrade release
                             'straiker-system'. Runs only after artifacts-sync completes.

Notes:
  - If a phase preflight is not met, the installer marks that phase BLOCKED and exits cleanly.
  - Re-run the same command after fixing prerequisites.
  - When eks-cluster just ran (or ran previously), straiker-system-helm auto-fills
    clusterName/eks.nodeRole from its Terraform outputs. Bringing your own cluster
    (no --install-eks) still requires those via --values.
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
      --tf-prefix)
        TF_PREFIX=${2:-}
        shift 2
        ;;
      --cluster-name)
        CLUSTER_NAME=${2:-}
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

# Asks once, only when this phase actually runs (skipped like any other phase
# once "done", so this isn't repeated on every retry). Mandatory — blocks rather
# than skipping if no valid credential is available (no tty, or a blank answer),
# since artifacts-sync and the customer's workloads depend on this having run.
prompt_for_straiker_credential() {
  if [[ -n "${STRAIKER_CREDENTIAL_FILE}" ]]; then
    return 0
  fi

  # Mandatory — later phases (artifacts-sync, and the customer's actual workloads
  # pulling images/models from ECR/S3) depend on this having run. --yes bypasses
  # the resource-creation *confirmation*, not this — there's no safe default to
  # fall back to, so a missing tty or a blank answer blocks rather than skips.
  local typed=""
  if [[ ! -e /dev/tty ]] || ! printf 'Straiker credential file for artifact syncing (required): ' 2>/dev/null > /dev/tty; then
    mark_phase_blocked "Straiker credential file is required for artifact syncing (no interactive terminal to ask). Re-run with --straiker-credential-file <path>."
    return 1
  fi

  if ! read -r typed < /dev/tty; then
    mark_phase_blocked "Straiker credential file is required for artifact syncing (no interactive terminal to ask). Re-run with --straiker-credential-file <path>."
    return 1
  fi

  if [[ -z "${typed}" || ! -f "${typed}" ]]; then
    mark_phase_blocked "A valid Straiker credential file is required for artifact syncing. Re-run with --straiker-credential-file <path>."
    return 1
  fi

  STRAIKER_CREDENTIAL_FILE="${typed}"
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

  prompt_for_straiker_credential || return

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

phase_straiker_system_helm() {
  require_command helm
  require_command kubectl

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

  local tf_cluster_name tf_node_role_arn
  tf_cluster_name="$(get_metadata "cluster_name")"
  tf_node_role_arn="$(get_metadata "karpenter_node_role_arn")"
  if [[ -n "${tf_cluster_name}" && -n "${tf_node_role_arn}" ]]; then
    log "Auto-filling clusterName/eks.nodeRole from this installer's Terraform outputs."
    cmd+=(--set "clusterName=${tf_cluster_name}" --set "eks.nodeRole=${tf_node_role_arn}")
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

  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  "${cmd[@]}"
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

  local typed=""
  if ! { read -r -p "> " typed < /dev/tty; } 2>/dev/null; then
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
    aws-artifacts) phase_aws_artifacts ;;
    artifacts-sync) phase_artifacts_sync ;;
    straiker-system-helm) phase_straiker_system_helm ;;
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
