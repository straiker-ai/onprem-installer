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

# GCP equivalents — only used when CLOUD_PROVIDER=gke.
GCP_TFBE_SRC="${REPO_ROOT}/terraform/gcp/tfbe"
GKE_SRC="${REPO_ROOT}/terraform/gcp/gke"
GCP_ARTIFACTS_SRC="${REPO_ROOT}/terraform/gcp/artifacts"

# Actual tofu runs happen under /tmp, not the bundle dir under $HOME — provider
# plugin downloads are hundreds of MB and $HOME may be tiny (e.g. AWS CloudShell's
# 1 GB home volume). A fixed path (not mktemp) lets .terraform/ provider caches
# and generated backend/tfvars survive across separate phase invocations.
TF_WORK_ROOT="${STRAIKER_TF_WORK_ROOT:-/tmp/straiker-tf}"
TFBE_DIR="${TF_WORK_ROOT}/aws/tfbe"
EKS_DIR="${TF_WORK_ROOT}/aws/eks"
ARTIFACTS_DIR="${TF_WORK_ROOT}/aws/artifacts"
GCP_TFBE_DIR="${TF_WORK_ROOT}/gcp/tfbe"
GKE_DIR="${TF_WORK_ROOT}/gcp/gke"
GCP_ARTIFACTS_DIR="${TF_WORK_ROOT}/gcp/artifacts"

# terraform/aws/eks's karpenter.tf provisions the AWS-side IAM/SQS/pod-identity
# resources; this installs the controller itself via its OCI chart.
KARPENTER_VERSION="1.14.0"
KARPENTER_NAMESPACE="karpenter"
# GKE equivalent: the community project's Helm chart (traditional repo, not
# OCI; CRDs and controller are separate charts).
# https://github.com/cloudpilot-ai/karpenter-provider-gcp/blob/main/docs/getting-started/installation.md
KARPENTER_GCP_HELM_REPO_NAME="karpenter-provider-gcp"
KARPENTER_GCP_HELM_REPO_URL="https://cloudpilot-ai.github.io/karpenter-provider-gcp"
KARPENTER_GCP_NAMESPACE="karpenter-system"
KARPENTER_GCP_VERSION="0.6.0"

# Shared provider plugin cache across tfbe and eks (both need hashicorp/aws)
# and across invocations — avoids re-downloading the same large provider.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${TF_WORK_ROOT}/plugin-cache}"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

HELM_REPO_NAME="straiker"
HELM_REPO_URL="https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist"
INFRA_RELEASE="straiker-system"
# Namespace shared by every Straiker chart this installer manages. Resolved
# (flag/persisted/prompt, defaulting to "straiker") by capture_install_config.
INFRA_NAMESPACE=""
INFRA_CHART_NAME="straiker-system"
# Installed before straiker-system, since that chart's workloads pull images
# through the ECR mirror this chart populates.
ARTIFACT_RELEASE="straiker-artifact"
ARTIFACT_CHART_NAME="straiker-artifact"
# Must match charts/straiker-artifact's default straikerCredentialSecretName.
STRAIKER_CREDENTIAL_SECRET_NAME="straiker-credential"

# Shared service-to-service credentials Secret read by straiker-core,
# straiker-inference, and straiker-defend; created by phase_shared_secrets.
SHARED_SECRETS_NAME="straiker-secrets"

# Application layer (frontend/bifrost/dex/caddy), installed into the same
# INFRA_NAMESPACE, after straiker-system.
APP_RELEASE="straiker-core"
APP_CHART_NAME="straiker-core"

# Product-gated GPU model servers (charts/straiker-inference) — one Helm
# release per model, installed independently so each can apply/fail/be
# checked on its own. Which models run is derived from PRODUCTS_OPT each
# time, not persisted separately.
INFERENCE_CHART_NAME="straiker-inference"
INFERENCE_SERVICE_ACCOUNT="straiker-inference"
# How many model releases phase_straiker_inference installs at once. Bounded
# so simultaneous GPU node provisioning doesn't risk the account's GPU quota,
# but high enough that one slow cold-start doesn't serialize every model.
INFERENCE_CONCURRENCY=4

# Argus detection engine (charts/straiker-defend) — Straiker's "Defend"
# product. Installed only when "defend" is in PRODUCTS_OPT, after
# straiker-inference and straiker-system.
DEFEND_RELEASE="straiker-defend"
DEFEND_CHART_NAME="straiker-defend"
DEFEND_SERVICE_ACCOUNT="straiker-defend"

# Iris automated red-teaming engine (charts/straiker-ascend) — Straiker's
# "Ascend" product. Installed only when "ascend" is in PRODUCTS_OPT, after
# straiker-inference, straiker-system, and straiker-core.
ASCEND_RELEASE="straiker-ascend"
ASCEND_CHART_NAME="straiker-ascend"

# Artifact broker's Bifrost-trial-config endpoint (AI_PROVIDER_MODE=trial-key
# below) -- fixed, same for every install. Returns {"virtual_key": "...",
# "base_url": "..."} for the authenticated customer.
ARTIFACT_BROKER_BIFROST_TRIAL_URL="https://us-central1-prod-registry-447007.cloudfunctions.net/onprem-artifact-broker/bifrost-trial"

# Resolves the customer's own tier (base/pro) so detect_customer_sku doesn't
# need it re-entered by hand.
ARTIFACT_BROKER_WHOAMI_URL="https://us-central1-prod-registry-447007.cloudfunctions.net/onprem-artifact-broker/whoami"

# Thin TLS edge (charts/straiker-edge) — routes app.<appDomain> to
# straiker-core's frontend and defend-api.<appDomain> to straiker-defend.
# Always runs; the defend-api route just 502s until straiker-defend is
# installed.
EDGE_RELEASE="straiker-edge"
EDGE_CHART_NAME="straiker-edge"

# Which cloud this install targets — aws (EKS) or gke. Determines which
# terraform/<provider>/ modules and cloud CLI every phase below calls.
#
# First-run-only: this is a foundational choice everything else depends on,
# so capture_install_config only reads it before it's persisted; once set,
# later invocations always use the stored value. To switch providers,
# delete ~/.straiker/install.json and start over.
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"

AWS_REGION="${AWS_REGION:-}"
# Only exported (see main()) if --aws-profile is passed, so a non-default
# SSO profile session actually reaches the bare aws/tofu calls below.
AWS_PROFILE_OPT="${AWS_PROFILE:-}"

# GCP equivalents of AWS_REGION/AWS_PROFILE_OPT — only used when
# CLOUD_PROVIDER=gke. gcloud credentials come from the caller's own
# environment (gcloud auth login); GCP_PROJECT_OPT just tells Terraform
# which project to target.
GCP_REGION="${GCP_REGION:-}"
GCP_PROJECT_OPT="${GOOGLE_CLOUD_PROJECT:-}"

# How much infrastructure phase_eks_cluster(_gke) provisions — min
# (single-AZ/zone, cheapest, PoC only, default), ha (multi-AZ/zone), or max
# (extra headroom). Same first-run-only treatment as CLOUD_PROVIDER, and for
# the same reason: changing a running cluster's AZ/NAT/node-pool topology in
# place isn't supported by either cloud's Terraform provider. Only
# meaningful when this installer provisions the cluster (--install-eks).
PROVISION_STRATEGY="${PROVISION_STRATEGY:-min}"

# How Ascend's recon-agent reaches an AI provider: own-keys (bring-your-own
# OpenAI/Anthropic/xAI key(s)), bedrock (AWS Bedrock, static IAM user
# credentials), or trial-key (a Straiker-hosted temporary virtual key,
# fetched automatically from the artifact broker). Only asked when 'ascend'
# is selected. Unlike CLOUD_PROVIDER/PROVISION_STRATEGY, safe to change on a
# later run via --ai-provider-mode — no Terraform state depends on it.
AI_PROVIDER_MODE="${AI_PROVIDER_MODE:-}"

# Provider credential values, captured interactively right after
# AI_PROVIDER_MODE is chosen. Held in memory only, never persisted to
# ~/.straiker/install.json; phase_ai_provider_secrets writes whichever of
# these are non-empty once the cluster/Secret exist.
AI_OPENAI_KEY=""
AI_ANTHROPIC_KEY=""
AI_XAI_KEY=""
AI_BEDROCK_ACCESS_KEY=""
AI_BEDROCK_SECRET_KEY=""
AI_BEDROCK_REGION=""
AI_TRIAL_VIRTUAL_KEY=""
# Fetched alongside AI_TRIAL_VIRTUAL_KEY from the same artifact-broker
# response.
AI_TRIAL_BIFROST_BASE_URL=""

TF_PREFIX="s6r-onprem"
CLUSTER_NAME=""
INSTALL_EKS=false
INSTALL_EKS_EXPLICIT=false
PROVISION_STRATEGY_EXPLICIT=false
AUTO_YES=false
PLAN_ONLY=false
STATUS_ONLY=false
FORCE_RERUN=false

SELECT_PHASE=""
START_PHASE=""
CHART_VERSION=""
HELM_TIMEOUT="20m"
# Straiker-issued per-customer identity for the artifact broker: name
# becomes the X-Customer-Email header (<name>@straiker.ai), key is the
# bearer token. Unlike every other credential in this script, these ARE
# persisted to ~/.straiker/install.json, since there's no way to re-derive
# them locally on a later run.
STRAIKER_CUSTOMER_NAME=""
STRAIKER_CUSTOMER_KEY=""
# Comma-separated canonical product names (ascend, defend), resolved/
# persisted by capture_install_config.
PRODUCTS_OPT=""

declare -a VALUES_FILES=()
declare -a ALL_PHASES=("eks-tfbe" "eks-cluster" "karpenter" "k8s-preflight" "aws-artifacts" "artifacts-sync" "straiker-system" "shared-secrets" "ai-provider-secrets" "straiker-core" "straiker-inference" "straiker-defend" "straiker-ascend" "straiker-edge")
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
  --status                        Show a per-phase summary (which is done/next/blocked) and exit.
                                   For the full raw state, read ~/.straiker/install.json directly.
  --phase <name>[,<name>...]       Run only the given phase(s), in the listed order.
  --from-phase <name>             Run from phase through the end.
  --rerun-phase                   Re-run selected phases even if already marked done.
  --install-eks                   Also provision an EKS cluster via Terraform (the AWS
                                   bootstrap phase runs regardless of this flag).
  --yes                           Skip the interactive resource-creation acknowledgement
                                   (for non-interactive/automated use).
  --cloud-provider <aws|gke>      Which cloud this install targets (default: aws). Determines
                                   which terraform/<provider>/ modules and cloud CLI (aws vs
                                   gcloud) every phase below actually calls. First-run-only:
                                   once set, this is permanent for the install recorded in
                                   ~/.straiker/install.json — later invocations ignore this flag
                                   and always use the stored value. To actually switch providers,
                                   delete that state file and start a fresh install.
  --provision-strategy <min|ha|max>
                                   How much infrastructure to provision when --install-eks is
                                   used (default: min). min = single-AZ/zone, cheapest, PoC only
                                   (an AZ/zone outage takes the whole service down). ha = multi-
                                   AZ/zone. max = extra headroom for maximum resilience. Same
                                   first-run-only treatment as --cloud-provider: permanent once
                                   set, ignored on later invocations. Irrelevant for bring-your-
                                   own-cluster installs.
  --aws-region <region>           AWS region (falls back to AWS_REGION/AWS_DEFAULT_REGION env,
                                   then the AWS CLI's configured region). Only used when
                                   --cloud-provider aws (the default).
  --aws-profile <name>            AWS CLI/SSO profile for every aws/tofu command this installer
                                   runs (falls back to the AWS_PROFILE env var). Needed whenever
                                   your credentials live under a non-default profile — otherwise
                                   `aws sso login --profile X` alone won't reach these commands.
  --gcp-region <region>           GCP region. Only used when --cloud-provider gke.
  --gcp-project <project-id>      GCP project ID (falls back to the GOOGLE_CLOUD_PROJECT env var).
                                   Only used when --cloud-provider gke. gcloud credentials
                                   themselves come from your existing `gcloud auth login` session
                                   — there's no gcloud equivalent of --aws-profile to pass here.
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
  --straiker-customer-name <name>  Your Straiker-assigned customer name (contact your rep if
                                   you don't have one). Required — if omitted, you'll be
                                   prompted interactively.
  --straiker-customer-key <key>   Your Straiker-assigned customer API key. Required — if
                                   omitted, you'll be prompted interactively.
  --products <list>               Comma-separated products to provision infra for: ascend,
                                   defend. Required — at least one. Determines which Karpenter
                                   NodePools straiker-system enables. Shared system services
                                   (OpenSearch/Postgres/Redis) install either way. If omitted,
                                   you'll be prompted interactively.
  --ai-provider-mode <own-keys|bedrock|trial-key>
                                   Only asked/used when 'ascend' is in --products. How Ascend's
                                   recon-agent reaches an AI provider: own-keys (bring your own
                                   OpenAI/Anthropic/xAI key(s)), bedrock (AWS Bedrock — you'll be
                                   shown the AWS CLI commands to set up IAM access), or trial-key
                                   (a Straiker-hosted temporary virtual key, up to 30 days,
                                   PoC/trial use only, fetched automatically — no separate key to
                                   hold). Unlike --cloud-provider/--provision-strategy, safe to
                                   change on a later run — just pass this flag
                                   again and re-run --phase ai-provider-secrets,straiker-core,
                                   straiker-ascend --rerun-phase. If omitted, you'll be prompted
                                   interactively the first time 'ascend' is selected.
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

# The broker identifies customers by a fixed <name>@straiker.ai header.
straiker_customer_email() {
  case "${STRAIKER_CUSTOMER_NAME}" in
    *@*) printf '%s' "${STRAIKER_CUSTOMER_NAME}" ;;
    *) printf '%s@straiker.ai' "${STRAIKER_CUSTOMER_NAME}" ;;
  esac
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

resolve_gcp_region() {
  if [[ -n "${GCP_REGION}" ]]; then
    return
  fi
  if command -v gcloud >/dev/null 2>&1; then
    GCP_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
  fi
}

resolve_gcp_project() {
  if [[ -n "${GCP_PROJECT_OPT}" ]]; then
    return
  fi
  if command -v gcloud >/dev/null 2>&1; then
    GCP_PROJECT_OPT="$(gcloud config get-value project 2>/dev/null || true)"
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

# One line per phase (done/blocked/in-progress/not-started) in ALL_PHASES
# order, with the first non-done phase marked "<- next" and any blocked
# phase's message printed underneath — a quick answer to "what phase are we
# on". For the full raw state (all metadata, timestamps, etc.), read
# ~/.straiker/install.json directly.
show_phase_summary() {
  ensure_state_file
  python3 - "${STATE_FILE}" "${STATE_SECTION}" "${ALL_PHASES[@]}" <<'PY'
import json, sys

path, section, *phases = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

phase_data = data.get(section, {}).get("phases", {})
icons = {"done": "✓", "skipped": "✓", "blocked": "✗", "in_progress": "⋯"}
# "skipped" (e.g. eks-cluster without --install-eks) is a legitimate resting
# state, same as "done", for the purpose of "what's actionable next" — only
# blocked/in_progress/not_started phases are candidates.
handled = {"done", "skipped"}

print("Phase status:")
next_marked = False
for phase in phases:
    info = phase_data.get(phase, {})
    status = info.get("status", "not_started")
    icon = icons.get(status, "·")
    marker = ""
    if not next_marked and status not in handled:
        marker = "  <- next"
        next_marked = True
    print(f"  {icon} {phase} ({status}){marker}")
    if status == "blocked" and info.get("message"):
        print(f"      {info['message']}")

if not next_marked:
    print("\nAll phases done.")
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
                             controller. Catches these here, rather than straiker-system
                             hanging for its full --wait timeout or failing late and unclearly.
  5) aws-artifacts        - create the ECR image mirror + models S3 bucket + hauler IAM role
                             (EKS Pod Identity). Always runs; needs a cluster to already exist
                             (ours via eks-cluster, or the customer's own via --cluster-name).
  6) artifacts-sync       - install/upgrade release 'straiker-artifact' (its own chart), which
                             creates the K8s Secret and runs the in-cluster image-mirror/model-sync
                             Jobs (plain resources, not Helm hooks — they can run for hours without
                             blocking this command). --straiker-customer-name/--straiker-customer-key
                             are required; you'll be prompted for them interactively if omitted.
                             Blocks the installer here until both Jobs report complete — re-run
                             --phase artifacts-sync any time to check again — since straiker-system's
                             workloads pull
                             images through the ECR mirror these Jobs populate.
  7) straiker-system      - add the public straiker Helm repo and install/upgrade release
                             'straiker-system'. Runs only after artifacts-sync completes.
  8) shared-secrets       - create the 'straiker-secrets' K8s Secret (once — leaves it alone
                             if it already exists) with freshly generated service-to-service
                             credentials: INTERNAL_API_KEY / SYS__FOUNDATION_API_KEY (same
                             value, Bearer-prefixed for argus since it sends the header
                             verbatim) for argus's settings-sync calls into straiker-core's
                             frontend, and VLLM_API_KEY / SYS__INFERENCE_API_KEY (same value)
                             for argus calling straiker-inference. All three charts already
                             hardcode this same Secret name; previously nothing ever created
                             it; each chart's own secrets.yaml is documentation-only.
  9) ai-provider-secrets  - only when 'ascend' is selected. Writes whichever provider
                             credential(s) AI_PROVIDER_MODE needs into 'straiker-secrets'
                             (own-keys: OpenAI/Anthropic/xAI; bedrock: static AWS
                             credentials; trial-key: a Straiker-issued temporary virtual
                             key). The interactive prompting itself (plus, for bedrock,
                             the printed AWS CLI IAM guidance) already happened earlier,
                             in capture_install_config right after you picked the mode —
                             this phase just performs the kubectl write once the
                             cluster/Secret are guaranteed ready. These are actual
                             credential values, never written to ~/.straiker/install.json.
 10) straiker-core        - install/upgrade release 'straiker-core' (frontend, bifrost,
                             dex, caddy — its own standalone chart). Runs after
                             straiker-system since frontend connects to that chart's
                             postgres/opensearch directly.
 11) straiker-inference   - install/upgrade one release per GPU model the selected products
                             need (charts/straiker-inference — Defend's argus needs antman/
                             hulk/quicksilver/thor/vision/wanda, Ascend's iris needs thanos).
                             Each model is its own release (named 'inference-<model>'), so one
                             model's GPU-capacity problem doesn't block the others. Skipped
                             entirely if no selected product needs a model.
 12) straiker-defend      - install/upgrade release 'straiker-defend' (argus + its
                             settings-sync daemon — charts/straiker-defend). Only when
                             'defend' is selected. Runs after straiker-inference (needs its
                             per-model Services) and straiker-system (needs its Redis/
                             OpenSearch/Benthos and shared NodePool).
 13) straiker-ascend      - install/upgrade release 'straiker-ascend' (iris automated
                             red-teaming engine — charts/straiker-ascend: control-plane,
                             probe-worker, probe-shadow, recon-worker, report-worker, and a
                             daily assessment-cleanup CronJob). Only when 'ascend' is
                             selected. Runs after straiker-core (shared Postgres via
                             straiker-system + frontend's admin-API callback), ai-provider-
                             secrets (trial-key's BIFROST_API_KEY), and straiker-inference
                             (needs inference-thanos).
 14) straiker-edge        - install/upgrade release 'straiker-edge' (thin TLS edge —
                             charts/straiker-edge). Always runs: routes app.<appDomain>
                             to straiker-core's frontend and defend.<appDomain> to
                             straiker-defend (502s until that's installed, if ever).

Notes:
  - If a phase preflight is not met, the installer marks that phase BLOCKED and exits cleanly.
  - Re-run the same command after fixing prerequisites.
  - straiker-system always auto-fills clusterName (captured/auto-detected up
    front, regardless of --install-eks). eks.nodeRole is auto-filled from Terraform
    outputs when eks-cluster provisioned the cluster itself, or otherwise detected
    from an existing EC2NodeClass on a bring-your-own cluster; --values can still
    override it explicitly if neither applies or picks the wrong one.
EOF
}

# Rough, illustrative on-demand list-price ballpark only -- not a quote.
# Region, reserved/spot/committed-use pricing, data transfer, storage IOPS,
# and NAT data-processing charges are NOT modeled; check the AWS/GCP pricing
# calculators for authoritative numbers. Every rate below is a single
# hardcoded approximation (roughly us-east-1 / us-central1, as of this
# writing) precisely because "rough" is the point -- this exists to give a
# ballpark before an install, not to replace a real cost tool.
show_cost_estimate() {
  local hours_per_month=730

  local models=()
  local model_line
  while IFS= read -r model_line; do
    [[ -n "${model_line}" ]] && models+=("${model_line}")
  done < <(inference_models_for_products)
  local gpu_node_count=${#models[@]}

  # Same 1/2/3 progression as terraform/aws/eks's system_node_sizing and
  # terraform/gcp/gke's zone_count locals -- both the AZ/zone count and the
  # system node count track provision_strategy identically in this
  # installer's actual terraform, so one variable covers both here.
  local az_or_zone_count
  case "${PROVISION_STRATEGY}" in
    min) az_or_zone_count=1 ;;
    max) az_or_zone_count=3 ;;
    *)   az_or_zone_count=2 ;;
  esac

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Rough monthly cost estimate — NOT A QUOTE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " cloud_provider=${CLOUD_PROVIDER} products=${PRODUCTS_OPT} provision_strategy=${PROVISION_STRATEGY}"
  echo " install_eks=${INSTALL_EKS} (bring-your-own-cluster costs aren't ours to estimate)"
  echo ""

  local total=0
  local line_cost

  if [[ "${INSTALL_EKS}" == true ]]; then
    if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
      # GKE: flat $0.10/hr cluster management fee for both zonal and
      # regional -- except one zonal cluster per billing account is free,
      # which this doesn't try to detect (shows the paid-tier number).
      line_cost="$(awk -v h="${hours_per_month}" 'BEGIN { printf "%.2f", 0.10 * h }')"
      echo " GKE control plane (mgmt fee, zonal-free-tier not detected): \$${line_cost}/mo"
      total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"

      line_cost="$(awk -v n="${az_or_zone_count}" -v h="${hours_per_month}" 'BEGIN { printf "%.2f", n * 0.134 * h }')"
      echo " System node pool (${az_or_zone_count}x e2-standard-4): \$${line_cost}/mo"
      total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"

      echo " Cloud NAT: usage-based (per-GB processed) — not modeled here"
    else
      line_cost="$(awk -v h="${hours_per_month}" 'BEGIN { printf "%.2f", 0.10 * h }')"
      echo " EKS control plane (flat fee): \$${line_cost}/mo"
      total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"

      line_cost="$(awk -v n="${az_or_zone_count}" -v h="${hours_per_month}" 'BEGIN { printf "%.2f", n * 0.096 * h }')"
      echo " System node group (${az_or_zone_count}x m5.large): \$${line_cost}/mo"
      total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"

      # 1 NAT gateway under min (see terraform/aws/eks's single_nat_gateway),
      # one per AZ otherwise. Base hourly charge only -- excludes
      # per-GB data processing.
      local nat_count=1
      [[ "${PROVISION_STRATEGY}" != "min" ]] && nat_count="${az_or_zone_count}"
      line_cost="$(awk -v n="${nat_count}" -v h="${hours_per_month}" 'BEGIN { printf "%.2f", n * 0.045 * h }')"
      echo " NAT gateway (${nat_count}x, base charge only, excludes data processing): \$${line_cost}/mo"
      total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"
    fi
    echo ""
  fi

  if [[ "${gpu_node_count}" -gt 0 ]]; then
    # One dedicated GPU node per model regardless of cloud (each inference
    # model is its own Karpenter-provisioned node in this installer's
    # design) -- g4dn.xlarge (AWS) / a T4-class equivalent (GKE), both
    # 16GB-tier, matching every current model's defaultGpuProfile: g4dn in
    # charts/straiker-inference.
    line_cost="$(awk -v n="${gpu_node_count}" -v h="${hours_per_month}" 'BEGIN { printf "%.2f", n * 0.526 * h }')"
    echo " GPU inference nodes (${gpu_node_count}x g4dn.xlarge-class, one per model: ${models[*]}): \$${line_cost}/mo"
    total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"
    echo ""
  else
    echo " No GPU inference models needed for products '${PRODUCTS_OPT}'."
    echo ""
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Estimated total: ~\$${total}/mo (compute only — see caveats above)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
    # Comma-separated so tightly-coupled phases (e.g. aws-artifacts,
    # artifacts-sync — the latter needs the former's outputs) can be retried
    # in one command instead of two, without forcing every later phase to
    # also re-run the way --from-phase --rerun-phase would.
    local IFS=','
    local requested=(${SELECT_PHASE})
    unset IFS
    local p
    for p in "${requested[@]}"; do
      if ! is_valid_phase "${p}"; then
        echo "ERROR: unknown phase '${p}'." >&2
        exit 1
      fi
      RUN_PHASES+=("${p}")
    done
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
      --cloud-provider)
        CLOUD_PROVIDER=${2:-}
        if [[ "${CLOUD_PROVIDER}" != "aws" && "${CLOUD_PROVIDER}" != "gke" ]]; then
          echo "ERROR: --cloud-provider must be 'aws' or 'gke', got '${CLOUD_PROVIDER}'." >&2
          exit 1
        fi
        shift 2
        ;;
      --provision-strategy)
        PROVISION_STRATEGY=${2:-}
        if [[ "${PROVISION_STRATEGY}" != "min" && "${PROVISION_STRATEGY}" != "ha" && "${PROVISION_STRATEGY}" != "max" ]]; then
          echo "ERROR: --provision-strategy must be 'min', 'ha', or 'max', got '${PROVISION_STRATEGY}'." >&2
          exit 1
        fi
        PROVISION_STRATEGY_EXPLICIT=true
        shift 2
        ;;
      --aws-region)
        AWS_REGION=${2:-}
        shift 2
        ;;
      --aws-profile)
        AWS_PROFILE_OPT=${2:-}
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
      --straiker-customer-name)
        STRAIKER_CUSTOMER_NAME=${2:-}
        shift 2
        ;;
      --straiker-customer-key)
        STRAIKER_CUSTOMER_KEY=${2:-}
        shift 2
        ;;
      --products)
        PRODUCTS_OPT=${2:-}
        shift 2
        ;;
      --ai-provider-mode)
        AI_PROVIDER_MODE=${2:-}
        if [[ "${AI_PROVIDER_MODE}" != "own-keys" && "${AI_PROVIDER_MODE}" != "bedrock" && "${AI_PROVIDER_MODE}" != "trial-key" ]]; then
          echo "ERROR: --ai-provider-mode must be 'own-keys', 'bedrock', or 'trial-key', got '${AI_PROVIDER_MODE}'." >&2
          exit 1
        fi
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

write_gke_backend_config() {
  local bucket_name=$1
  local dir=$2
  local key=$3
  cat > "${dir}/backend.tf" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
terraform {
  backend "gcs" {
    bucket = "${bucket_name}"
    prefix = "s6r-onprem/${key}"
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
  # provision_strategy=max gets a 3rd AZ registered (matching this module's
  # own availability_zones variable description: "3 for maximum
  # resilience") -- min/ha both still register 2 (EKS's hard minimum for
  # the control plane; provision_strategy=min just confines the node
  # group/NAT/Karpenter discovery to the first of the two, see
  # terraform/aws/eks/locals.tf).
  local az_count=2
  [[ "${PROVISION_STRATEGY}" == "max" ]] && az_count=3

  local azs az_json az1
  azs="$(aws ec2 describe-availability-zones \
    --region "${AWS_REGION}" \
    --filters Name=state,Values=available \
    --query "AvailabilityZones[:${az_count}].ZoneName" \
    --output text)"

  read -r az1 _ <<< "${azs}"
  if [[ -z "${az1:-}" || $(echo "${azs}" | wc -w) -lt "${az_count}" ]]; then
    mark_phase_blocked "Could not resolve ${az_count} availability zones for region '${AWS_REGION}'."
    return
  fi

  az_json="$(printf '"%s", ' ${azs})"
  az_json="[${az_json%, }]"

  cat > "${EKS_DIR}/terraform.auto.tfvars" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
region             = "${AWS_REGION}"
availability_zones = ${az_json}
cluster_name       = "${CLUSTER_NAME}"
provision_strategy = "${PROVISION_STRATEGY}"
EOF
  # aws cli's --output text is tab-separated, not space-separated -- tr -s
  # over both collapses either into one comma, then strip stray leading/
  # trailing ones.
  local azs_csv
  azs_csv="$(echo "${azs}" | tr -s '[:space:]' ',')"
  azs_csv="${azs_csv#,}"
  azs_csv="${azs_csv%,}"
  set_metadata "availability_zones" "${azs_csv}"
}

resolve_bucket_name() {
  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  echo "${TF_PREFIX}-tfstate-${AWS_REGION}-${account_id}"
}

# On AWS, the "ecr_registry" metadata value is the bare ECR host (e.g.
# 123.dkr.ecr.us-east-1.amazonaws.com) and needs "/${TF_PREFIX}" appended to
# form the actual repo-path prefix every image reference uses. On GKE, that
# same metadata key (reused generically — see phase_aws_artifacts_gke) is
# already the full Artifact Registry host INCLUDING the repo name (which IS
# ${TF_PREFIX}), so appending it again would duplicate it.
docker_registry_with_prefix() {
  local base=$1
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    echo "${base}"
  else
    echo "${base}/${TF_PREFIX}"
  fi
}

# global.modelBucket needs the right scheme prefix for whichever backend
# charts/straiker-inference's/straiker-defend's modelSyncCmd helper uses
# (aws s3 sync vs gsutil rsync) — the bare "models_bucket" metadata value
# never carries one itself.
model_bucket_uri() {
  local bucket=$1
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    echo "gs://${bucket}"
  else
    echo "s3://${bucket}"
  fi
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

  # kubectl talking to a managed cluster shells out to the matching cloud CLI
  # for auth on every call (`aws eks get-token` on EKS, a gcloud
  # auth-provider plugin on GKE). Expired credentials there make kubectl
  # report a generic "couldn't reach the cluster" error — even though the
  # cluster is fine and already recorded in state. Check the relevant cloud's
  # credentials directly first so that actual cause isn't misreported as a
  # missing or never-configured cluster context.
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    if command -v gcloud >/dev/null 2>&1 && ! gcloud auth print-access-token >/dev/null 2>&1; then
      echo "ERROR: gcloud credentials are invalid or expired — that's why kubectl can't reach the cluster (GKE auth shells out to gcloud on every call)." >&2
      echo "       Refresh them ('gcloud auth login', and 'gcloud auth application-default login' if Terraform is also affected) and try again." >&2
      exit 1
    fi
  else
    if command -v aws >/dev/null 2>&1 && ! aws sts get-caller-identity >/dev/null 2>&1; then
      echo "ERROR: AWS credentials are invalid or expired — that's why kubectl can't reach the cluster (EKS auth shells out to AWS on every call)." >&2
      echo "       Refresh them (e.g. 'aws sso login', or re-run 'aws configure') and try again." >&2
      exit 1
    fi
  fi

  if [[ "${INSTALL_EKS}" == false ]]; then
    echo "ERROR: Kubernetes is not reachable and --install-eks was not enabled." >&2
    echo "       Either provide a working cluster context or re-run with --install-eks." >&2
    exit 1
  fi
  mark_phase_blocked "Kubernetes API is not reachable yet. Re-run after cluster is ready."
  return 1
}

phase_eks_tfbe() {
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    phase_eks_tfbe_gke
    return
  fi

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

# GCS equivalent of the AWS branch above — GCS bucket names are also
# globally unique, so the same "check if it already exists, import instead
# of letting apply fail" pattern applies.
phase_eks_tfbe_gke() {
  if [[ -z "${GCP_REGION}" || -z "${GCP_PROJECT_OPT}" ]]; then
    mark_phase_blocked "GCP region and project are required. Use --gcp-region/--gcp-project, or configure gcloud."
    return
  fi

  require_command gcloud
  require_command tofu
  require_terraform_dir "${GCP_TFBE_SRC}" || return
  sync_terraform_workdir "${GCP_TFBE_SRC}" "${GCP_TFBE_DIR}"

  tofu -chdir="${GCP_TFBE_DIR}" init -upgrade -input=false

  local bucket_name="${TF_PREFIX}-tfstate-${GCP_REGION}-${GCP_PROJECT_OPT}"
  if gcloud storage buckets describe "gs://${bucket_name}" >/dev/null 2>&1; then
    log "Bucket '${bucket_name}' already exists — importing into Terraform state instead of recreating it."
    tofu -chdir="${GCP_TFBE_DIR}" import \
      -var="region=${GCP_REGION}" -var="prefix=${TF_PREFIX}" -var="project_id=${GCP_PROJECT_OPT}" \
      google_storage_bucket.tfstate "${bucket_name}" 2>/dev/null || true
  fi

  tofu -chdir="${GCP_TFBE_DIR}" apply \
    -var="region=${GCP_REGION}" -var="prefix=${TF_PREFIX}" -var="project_id=${GCP_PROJECT_OPT}" \
    -auto-approve -input=false

  bucket_name="$(tofu -chdir="${GCP_TFBE_DIR}" output -raw bucket_name)"
  set_metadata "gcp_region" "${GCP_REGION}"
  set_metadata "gcp_project" "${GCP_PROJECT_OPT}"
  set_metadata "tf_prefix" "${TF_PREFIX}"
  set_metadata "bootstrap_bucket" "${bucket_name}"
}

phase_eks_cluster() {
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    phase_eks_cluster_gke
    return
  fi

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

phase_eks_cluster_gke() {
  if [[ "${INSTALL_EKS}" == false ]]; then
    log "Skipping GKE cluster provisioning; pass --install-eks to provision one (bring-your-own-cluster expected otherwise)."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--install-eks not set."
    return
  fi
  if [[ -z "${GCP_REGION}" || -z "${GCP_PROJECT_OPT}" ]]; then
    mark_phase_blocked "GCP region and project are required for GKE provisioning. Use --gcp-region/--gcp-project."
    return
  fi

  require_command gcloud
  require_command tofu
  require_command kubectl
  require_terraform_dir "${GKE_SRC}" || return
  sync_terraform_workdir "${GKE_SRC}" "${GKE_DIR}"

  local bucket_name
  bucket_name="$(get_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    mark_phase_blocked "Bootstrap bucket not found in state. Run phase 'eks-tfbe' first."
    return
  fi

  write_gke_backend_config "${bucket_name}" "${GKE_DIR}" "gke"

  tofu -chdir="${GKE_DIR}" init -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${GKE_DIR}" apply -auto-approve -input=false \
    -var="region=${GCP_REGION}" -var="project_id=${GCP_PROJECT_OPT}" -var="cluster_name=${CLUSTER_NAME}" \
    -var="provision_strategy=${PROVISION_STRATEGY}"

  local cluster_name cluster_endpoint cluster_location karpenter_sa karpenter_node_sa
  cluster_name="$(tofu -chdir="${GKE_DIR}" output -raw cluster_name)"
  cluster_endpoint="$(tofu -chdir="${GKE_DIR}" output -raw cluster_endpoint)"
  cluster_location="$(tofu -chdir="${GKE_DIR}" output -raw cluster_location)"
  karpenter_sa="$(tofu -chdir="${GKE_DIR}" output -raw karpenter_service_account_email)"
  karpenter_node_sa="$(tofu -chdir="${GKE_DIR}" output -raw karpenter_node_service_account_email)"
  # --location (zone or region), not --region -- under provision_strategy=min
  # the cluster is zonal, and --region would fail against it.
  gcloud container clusters get-credentials "${cluster_name}" --location "${cluster_location}" --project "${GCP_PROJECT_OPT}" >/dev/null

  # GKE's own CSI driver ships a StorageClass named "standard-rwo" by
  # default on modern clusters, already marked default — unlike EKS's
  # aws-ebs-csi-driver addon (which installs the driver but no
  # StorageClass), so there's no equivalent manual step needed here.

  set_metadata "cluster_name" "${cluster_name}"
  set_metadata "cluster_endpoint" "${cluster_endpoint}"
  set_metadata "cluster_location" "${cluster_location}"
  set_metadata "karpenter_service_account_email" "${karpenter_sa}"
  set_metadata "karpenter_node_service_account_email" "${karpenter_node_sa}"
}

phase_karpenter() {
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    phase_karpenter_gke
    return
  fi

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

phase_karpenter_gke() {
  if [[ "${INSTALL_EKS}" == false ]]; then
    log "Skipping Karpenter controller install; pass --install-eks to also install it (bring-your-own-cluster is expected to manage its own Karpenter, if any)."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--install-eks not set."
    return
  fi

  require_command helm
  require_command kubectl

  local cluster_name karpenter_sa karpenter_node_sa
  cluster_name="$(get_metadata "cluster_name")"
  karpenter_sa="$(get_metadata "karpenter_service_account_email")"
  karpenter_node_sa="$(get_metadata "karpenter_node_service_account_email")"

  if [[ -z "${cluster_name}" || -z "${karpenter_sa}" || -z "${karpenter_node_sa}" ]]; then
    # Same re-read-from-Terraform-state fallback as the AWS branch, for a
    # gke-cluster phase that completed under an older installer version.
    log "cluster_name/karpenter service account emails missing from install state (likely completed under an older installer version) — reading directly from Terraform state instead."
    if [[ -z "${GCP_REGION}" || -z "${GCP_PROJECT_OPT}" ]]; then
      mark_phase_blocked "GCP region and project are required. Use --gcp-region/--gcp-project."
      return
    fi
    require_command gcloud
    require_command tofu
    require_terraform_dir "${GKE_SRC}" || return
    sync_terraform_workdir "${GKE_SRC}" "${GKE_DIR}"

    local bucket_name
    bucket_name="$(get_metadata "bootstrap_bucket")"
    if [[ -z "${bucket_name}" ]]; then
      mark_phase_blocked "Bootstrap bucket not found. Run phase 'eks-tfbe' first."
      return
    fi

    write_gke_backend_config "${bucket_name}" "${GKE_DIR}" "gke"
    tofu -chdir="${GKE_DIR}" init -upgrade -input=false -migrate-state -force-copy

    cluster_name="$(tofu -chdir="${GKE_DIR}" output -raw cluster_name 2>/dev/null || echo "")"
    karpenter_sa="$(tofu -chdir="${GKE_DIR}" output -raw karpenter_service_account_email 2>/dev/null || echo "")"
    karpenter_node_sa="$(tofu -chdir="${GKE_DIR}" output -raw karpenter_node_service_account_email 2>/dev/null || echo "")"
    if [[ -z "${cluster_name}" || -z "${karpenter_sa}" || -z "${karpenter_node_sa}" ]]; then
      mark_phase_blocked "Could not read cluster_name/karpenter service account emails from Terraform state either. Run phase 'eks-cluster' (add --rerun-phase if it's marked done) first."
      return
    fi
    set_metadata "cluster_name" "${cluster_name}"
    set_metadata "karpenter_service_account_email" "${karpenter_sa}"
    set_metadata "karpenter_node_service_account_email" "${karpenter_node_sa}"
  fi

  helm repo add --force-update "${KARPENTER_GCP_HELM_REPO_NAME}" "${KARPENTER_GCP_HELM_REPO_URL}" >/dev/null
  helm repo update "${KARPENTER_GCP_HELM_REPO_NAME}" >/dev/null

  # CRDs are a separate chart so `helm upgrade` on the controller chart alone
  # still upgrades them — same reasoning the project's own docs give.
  helm upgrade --install karpenter-crd "${KARPENTER_GCP_HELM_REPO_NAME}/karpenter-crd" \
    --version "${KARPENTER_GCP_VERSION}" \
    --wait --timeout "${HELM_TIMEOUT}"

  helm upgrade --install karpenter "${KARPENTER_GCP_HELM_REPO_NAME}/karpenter" \
    --version "${KARPENTER_GCP_VERSION}" \
    --namespace "${KARPENTER_GCP_NAMESPACE}" \
    --create-namespace \
    --set "controller.settings.projectID=${GCP_PROJECT_OPT}" \
    --set "controller.settings.clusterLocation=${GCP_REGION}" \
    --set "controller.settings.clusterName=${cluster_name}" \
    --set "controller.settings.defaultNodepoolServiceAccount=${karpenter_node_sa}" \
    --set "credentials.enabled=false" \
    --set "serviceAccount.annotations.iam\.gke\.io/gcp-service-account=${karpenter_sa}" \
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
# needs it) and only fail deep inside straiker-system's chart render, via
# its NodePool templates' own `fail "Karpenter is not installed"` check — late
# and unclear compared to catching it here.
phase_k8s_preflight() {
  require_command kubectl

  if ! kubectl cluster-info >/dev/null 2>&1; then
    # See ensure_k8s_ready_for_charts's comment: EKS/GKE auth shells out to
    # the matching cloud CLI on every kubectl call, so an expired session
    # (not a cluster/context problem at all) surfaces here as the same
    # generic unreachable error.
    if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
      if command -v gcloud >/dev/null 2>&1 && ! gcloud auth print-access-token >/dev/null 2>&1; then
        mark_phase_blocked "gcloud credentials are invalid or expired — that's why kubectl can't reach the cluster (GKE auth shells out to gcloud on every call). Refresh them ('gcloud auth login') and re-run."
      elif [[ "${INSTALL_EKS}" == true ]]; then
        local hint_location
        hint_location="$(get_metadata "cluster_location")"
        [[ -z "${hint_location}" ]] && hint_location="${GCP_REGION}"
        mark_phase_blocked "Kubernetes API not reachable even after eks-cluster ran. Check: gcloud container clusters get-credentials ${CLUSTER_NAME} --location ${hint_location} --project ${GCP_PROJECT_OPT}."
      else
        mark_phase_blocked "Kubernetes API not reachable. Point kubectl at your existing cluster (gcloud container clusters get-credentials <name> --location <zone-or-region> --project <project>), or re-run with --install-eks to provision one."
      fi
    else
      if command -v aws >/dev/null 2>&1 && ! aws sts get-caller-identity >/dev/null 2>&1; then
        mark_phase_blocked "AWS credentials are invalid or expired — that's why kubectl can't reach the cluster (EKS auth shells out to AWS on every call). Refresh them (e.g. 'aws sso login') and re-run."
      elif [[ "${INSTALL_EKS}" == true ]]; then
        mark_phase_blocked "Kubernetes API not reachable even after eks-cluster ran. Check: aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}."
      else
        mark_phase_blocked "Kubernetes API not reachable. Point kubectl at your existing cluster (aws eks update-kubeconfig --region <region> --name <cluster>), or re-run with --install-eks to provision one."
      fi
    fi
    return
  fi

  # A StorageClass — required for opensearch's PVC to ever bind (its
  # persistence.storageClass value is "", i.e. "use the cluster default").
  # Checked regardless of --install-eks: our own eks-cluster phase creates a
  # default one, but this is what actually catches it here instead of
  # straiker-system silently hanging for its full --wait timeout on a pod
  # that can never schedule. Prefer a real default; if there isn't one but
  # exactly one StorageClass exists at all, use it explicitly (persisted for
  # phase_straiker_system to --set) rather than making the customer go
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
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    phase_aws_artifacts_gke
    return
  fi

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
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="namespace=${INFRA_NAMESPACE}" \
    -var="workload_namespace=${INFRA_NAMESPACE}" \
    -var="workload_service_account_names=[\"${INFERENCE_SERVICE_ACCOUNT}\", \"${DEFEND_SERVICE_ACCOUNT}\"]"

  local models_bucket ecr_registry hauler_role_arn workload_role_arn
  models_bucket="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw models_bucket_name)"
  ecr_registry="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw ecr_registry)"
  hauler_role_arn="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw hauler_role_arn)"
  workload_role_arn="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw workload_role_arn)"

  set_metadata "models_bucket" "${models_bucket}"
  set_metadata "ecr_registry" "${ecr_registry}"
  set_metadata "hauler_role_arn" "${hauler_role_arn}"
  set_metadata "workload_role_arn" "${workload_role_arn}"
}

# GCP equivalent. Stores the Artifact Registry host under the SAME
# "ecr_registry" metadata key the AWS branch uses (and every downstream
# phase already reads) rather than a parallel gke-specific key — it's
# already just "the destination registry" regardless of cloud, matching
# charts/straiker-artifact's own ecrRegistry value reuse.
phase_aws_artifacts_gke() {
  if [[ -z "${GCP_REGION}" || -z "${GCP_PROJECT_OPT}" ]]; then
    mark_phase_blocked "GCP region and project are required. Use --gcp-region/--gcp-project."
    return
  fi

  require_command gcloud
  require_command tofu
  require_terraform_dir "${GCP_ARTIFACTS_SRC}" || return
  sync_terraform_workdir "${GCP_ARTIFACTS_SRC}" "${GCP_ARTIFACTS_DIR}"

  local bucket_name
  bucket_name="$(get_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    mark_phase_blocked "Bootstrap bucket not found in state. Run phase 'eks-tfbe' first."
    return
  fi

  # Workload Identity bindings below don't require the cluster to already
  # exist the way EKS Pod Identity associations do (they bind a K8s SA
  # identity that doesn't need to be validated against a live cluster at
  # apply time) — so unlike the AWS branch, there's no equivalent
  # "describe-cluster or fail" precondition needed here.

  write_gke_backend_config "${bucket_name}" "${GCP_ARTIFACTS_DIR}" "artifacts"

  tofu -chdir="${GCP_ARTIFACTS_DIR}" init -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${GCP_ARTIFACTS_DIR}" apply -auto-approve -input=false \
    -var="region=${GCP_REGION}" \
    -var="project_id=${GCP_PROJECT_OPT}" \
    -var="prefix=${TF_PREFIX}" \
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="namespace=${INFRA_NAMESPACE}" \
    -var="workload_namespace=${INFRA_NAMESPACE}" \
    -var="workload_service_account_names=[\"${INFERENCE_SERVICE_ACCOUNT}\", \"${DEFEND_SERVICE_ACCOUNT}\"]"

  local models_bucket registry_host hauler_sa workload_sa
  models_bucket="$(tofu -chdir="${GCP_ARTIFACTS_DIR}" output -raw models_bucket_name)"
  registry_host="$(tofu -chdir="${GCP_ARTIFACTS_DIR}" output -raw artifact_registry_host)"
  hauler_sa="$(tofu -chdir="${GCP_ARTIFACTS_DIR}" output -raw hauler_service_account_email)"
  workload_sa="$(tofu -chdir="${GCP_ARTIFACTS_DIR}" output -raw workload_service_account_email)"

  set_metadata "models_bucket" "${models_bucket}"
  set_metadata "ecr_registry" "${registry_host}"
  set_metadata "hauler_service_account_email" "${hauler_sa}"
  set_metadata "workload_service_account_email" "${workload_sa}"
}

# Resolves the customer's SKU/tier from the artifact broker. Echoes "base"
# if it can't be determined — a safe default, since sku: "base" images in
# charts/straiker-artifact are always attempted regardless, and this only
# widens or narrows what else gets attempted.
detect_customer_sku() {
  local sku
  sku="$(curl -sf -H "Authorization: Bearer ${STRAIKER_CUSTOMER_KEY}" -H "X-Customer-Email: $(straiker_customer_email)" "${ARTIFACT_BROKER_WHOAMI_URL}" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tier",""))' 2>/dev/null)"
  echo "${sku:-base}"
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
# the installer here until both report complete — straiker-system's workloads
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
    ecr_registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"

    helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
    helm repo update "${HELM_REPO_NAME}" >/dev/null

    kubectl create namespace "${INFRA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    local credential_json
    credential_json="$(python3 -c 'import json,sys; print(json.dumps({"api_key": sys.argv[1], "customer_email": sys.argv[2]}))' "${STRAIKER_CUSTOMER_KEY}" "$(straiker_customer_email)")"
    kubectl create secret generic "${STRAIKER_CREDENTIAL_SECRET_NAME}" \
      --namespace "${INFRA_NAMESPACE}" \
      --from-literal="key.json=${credential_json}" \
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

    local artifact_cmd=(
      helm upgrade --install "${ARTIFACT_RELEASE}" "${HELM_REPO_NAME}/${ARTIFACT_CHART_NAME}"
      --namespace "${INFRA_NAMESPACE}"
      --create-namespace
      --set "straikerCredentialSecretName=${STRAIKER_CREDENTIAL_SECRET_NAME}"
      --set "ecrRegistry=${ecr_registry_prefixed}"
      --set "modelsBucket=${models_bucket}"
      --set "customerSku=${customer_sku}"
      --set "imageMirror.enabled=true"
      --set "modelSync.enabled=true"
    )
    # Only sync the models the selected products actually need (same
    # inference_models_for_products mapping phase_straiker_inference's
    # per-model release loop uses) rather than every model this chart knows
    # about — each one is ~10GB, and most installs only ever deploy a
    # subset. Helm's --set "{a,b,c}" list syntax, comma-joined from the
    # same function output, not a second hardcoded model list.
    local sync_models=()
    local sync_model_line
    while IFS= read -r sync_model_line; do
      [[ -n "${sync_model_line}" ]] && sync_models+=("${sync_model_line}")
    done < <(inference_models_for_products)
    if [[ ${#sync_models[@]} -gt 0 ]]; then
      local sync_models_csv
      sync_models_csv="$(IFS=','; echo "${sync_models[*]}")"
      artifact_cmd+=(--set "modelSync.enabledModels={${sync_models_csv}}")
    fi
    if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
      artifact_cmd+=(--set "cloudProvider=gke")
      local hauler_sa
      hauler_sa="$(get_metadata "hauler_service_account_email")"
      if [[ -n "${hauler_sa}" ]]; then
        artifact_cmd+=(--set "gcpServiceAccountEmail=${hauler_sa}")
      fi
    fi
    # Not --wait: these Jobs can run for hours (large model syncs) and must not
    # block this command synchronously. set -e + the ERR trap already mark this
    # phase "failed" and abort if the helm command itself errors; the polling
    # below separately catches the Jobs themselves failing after being created.
    "${artifact_cmd[@]}"
  fi

  local pending=false failed=false status

  status="$(check_artifact_job "straiker-artifact-image-mirror")"
  [[ "${status}" == "failed" ]] && failed=true
  [[ "${status}" != "complete" ]] && pending=true

  status="$(check_artifact_job "straiker-artifact-model-sync")"
  [[ "${status}" == "failed" ]] && failed=true
  [[ "${status}" != "complete" ]] && pending=true

  if [[ "${failed}" == true ]]; then
    mark_phase_blocked "Artifact sync FAILED (a Job exhausted its retries) — see the kubectl logs hint above. straiker-system will not run until this is resolved. Fix the underlying issue, delete the failed Job(s) in namespace '${INFRA_NAMESPACE}', then re-run --phase artifacts-sync."
    return
  fi

  if [[ "${pending}" == true ]]; then
    mark_phase_blocked "Artifact sync still running in-cluster (it survives this command exiting). straiker-system will not run until this completes. Re-run --phase artifacts-sync any time to check again."
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

  # Both annotations must match, not just release-name — a resource adopted
  # under a previous INFRA_NAMESPACE (e.g. after a namespace rename) still has
  # the same release-name but a stale release-namespace, which Helm's own
  # ownership check rejects just as hard as an entirely unmanaged resource.
  local owner owner_ns
  owner="$(kubectl get "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} \
    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
  owner_ns="$(kubectl get "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} \
    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)"
  [[ "${owner}" == "${INFRA_RELEASE}" && "${owner_ns}" == "${INFRA_NAMESPACE}" ]] && return 0

  log "Adopting existing ${kind} '${name}' into release '${INFRA_RELEASE}/${INFRA_NAMESPACE}' (unmanaged, or owned under a stale namespace)."
  kubectl annotate "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} \
    "meta.helm.sh/release-name=${INFRA_RELEASE}" \
    "meta.helm.sh/release-namespace=${INFRA_NAMESPACE}" --overwrite >/dev/null
  kubectl label "${kind}" "${name}" ${ns_args[@]+"${ns_args[@]}"} \
    "app.kubernetes.io/managed-by=Helm" --overwrite >/dev/null
}

phase_straiker_system() {
  require_command helm
  require_command kubectl

  # Known collision: charts/straiker-system's default nvidia.runtimeClass.name
  # ("nvidia") often already exists on clusters with GPU support pre-configured
  # (e.g. NVIDIA GPU Operator). Only covers that default name — a customer
  # overriding it via --values to something else would need the same manual
  # `kubectl annotate`/`kubectl label` fix for their custom name.
  adopt_existing_resource "runtimeclass" "nvidia" ""

  # Same class of collision for Karpenter's own cluster-scoped resources —
  # NodePool/EC2NodeClass (or GCENodeClass, on gke) have no namespace of
  # their own, so a prior install's release-namespace annotation (e.g.
  # before an INFRA_NAMESPACE rename) goes stale independently of whatever
  # k8s namespace holds the rest of the release. Only covers
  # charts/straiker-system's default straiker-{gpu,argus,iris,shared} names
  # — a customer overriding those via --values needs the same manual fix
  # for their custom names. No-ops for names that don't exist (e.g.
  # argus/iris NodePools not selected via --products).
  local node_class_kind
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    node_class_kind="gcenodeclass"
  else
    node_class_kind="ec2nodeclass"
  fi
  local nc_name
  for nc_name in straiker-gpu straiker-argus straiker-iris straiker-shared; do
    adopt_existing_resource "nodepool" "${nc_name}" ""
    adopt_existing_resource "${node_class_kind}" "${nc_name}" ""
  done

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

  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    cmd+=(--set "cloudProvider=gke")
    # No GKE equivalent of eks.nodeRole to fill in here: GCENodeClass has no
    # serviceAccount field of its own (unlike EC2NodeClass's role) — the
    # default node identity for Karpenter-launched instances is set once,
    # cluster-wide, via phase_karpenter_gke's
    # controller.settings.defaultNodepoolServiceAccount Helm flag instead.
  else
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
  fi

  # aws-artifacts (mandatory, runs before this) always provisions the ECR mirror,
  # and artifacts-sync (also mandatory, runs before this) always blocks until it's
  # populated — so it's always safe to point pulls at it once it exists.
  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  if [[ -n "${ecr_registry}" ]]; then
    local ecr_registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"
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

# Creates SHARED_SECRETS_NAME once, idempotently — never regenerated or
# patched on later runs (that would rotate credentials the frontend/inference/
# defend releases already picked up, breaking their already-working
# integrations). If the customer wants to rotate a key, that's a manual
# `kubectl edit secret` followed by restarting the consumers, not something
# this installer does automatically.
#
# INTERNAL_API_KEY / SYS__FOUNDATION_API_KEY share one underlying value: the
# frontend app strips a "Bearer " prefix before comparing the inbound header
# against INTERNAL_API_KEY, while argus sends SYS__FOUNDATION_API_KEY
# verbatim as the whole header — so the same secret has to be stored twice,
# once bare and once pre-prefixed, rather than templated at the chart level
# (Kubernetes Secrets don't support computed values). Verified directly
# against straiker/frontend's apps/web/src/lib/server/hooks/authorization.ts
# and straiker/argus's argus/common/settings/settings.py.
#
# VLLM_API_KEY / SYS__INFERENCE_API_KEY share the other value verbatim (no
# prefix games) — straiker-inference's vLLM server checks this key as a
# plain bearer token, same as argus does.
phase_shared_secrets() {
  require_command kubectl
  require_command openssl

  if kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    log "Secret '${SHARED_SECRETS_NAME}' already exists in namespace '${INFRA_NAMESPACE}' — leaving its values as-is."
    return
  fi

  ensure_k8s_ready_for_charts || return

  # hex, not base64 — these end up in HTTP Authorization headers verbatim
  # (see the phase's own comment above), and hex has no +/= characters to
  # worry about there or in shell interpolation.
  local internal_key inference_key iris_admin_key
  internal_key="$(openssl rand -hex 32)"
  inference_key="$(openssl rand -hex 32)"
  # charts/straiker-core's frontend sends this as "Authorization: Bearer
  # <value>"; charts/straiker-ascend's control-plane compares it via
  # FastAPI's HTTPBearer, which strips "Bearer " before comparing -- so
  # unlike SYS__FOUNDATION_API_KEY above, the SAME raw value is stored on
  # both sides, no prefix baked in. Verified against iris/iris.py's
  # verify_api_key and frontend's iris/client.ts.
  iris_admin_key="$(openssl rand -hex 32)"

  kubectl create secret generic "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" \
    --from-literal="INTERNAL_API_KEY=${internal_key}" \
    --from-literal="SYS__FOUNDATION_API_KEY=Bearer ${internal_key}" \
    --from-literal="VLLM_API_KEY=${inference_key}" \
    --from-literal="SYS__INFERENCE_API_KEY=${inference_key}" \
    --from-literal="IRIS_ADMIN_API_KEY=${iris_admin_key}" \
    >/dev/null
  log "Created Secret '${SHARED_SECRETS_NAME}' with freshly generated service-to-service credentials."
}

# $1=key name (e.g. "SYS__OPENAI_API_KEY"). True if that key already has a
# non-empty value in the shared secret. Used for per-mode idempotency below
# instead of tracking "already asked" in ~/.straiker/install.json — the
# own-keys/bedrock provider credential values this gates are never persisted
# to disk, so the live Secret itself is the only available source of truth
# for "do we still need to ask."
secret_key_exists() {
  local key=$1
  local val
  val="$(kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" -o jsonpath="{.data.${key}}" 2>/dev/null || true)"
  [[ -n "${val}" ]]
}

# $1=key $2=value. Merge-patches a single key into the already-existing
# shared secret without disturbing any other key — unlike phase_shared_secrets'
# own `kubectl create secret`, which only ever runs once against a
# not-yet-existing Secret. Piped through python3 for JSON-safe escaping since
# provider API keys can contain characters (+, /, =) that break naive shell
# quoting.
patch_shared_secret() {
  local key=$1 value=$2
  local patch_json
  patch_json="$(python3 -c 'import json,sys; print(json.dumps({"stringData": {sys.argv[1]: sys.argv[2]}}))' "${key}" "${value}")"
  kubectl patch secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" --type=merge -p "${patch_json}" >/dev/null
}

# Writes whichever provider-specific keys AI_PROVIDER_MODE needs into
# straiker-secrets, using the AI_OPENAI_KEY/AI_ANTHROPIC_KEY/AI_XAI_KEY/
# AI_BEDROCK_ACCESS_KEY/AI_BEDROCK_SECRET_KEY/AI_TRIAL_VIRTUAL_KEY values
# capture_install_config already collected interactively (see its own
# comment for why the actual prompting happens there, not here). This phase
# just does the kubectl write, once the cluster/Secret are guaranteed ready
# — nothing here is interactive. Only relevant when 'ascend' is selected.
# Runs after shared-secrets (needs the base Secret to already exist) and
# before straiker-core/straiker-ascend, since bifrost/ascend's pods only
# read secretKeyRef env vars at container start — if you're re-running this
# after already deploying either release (e.g. switching modes later), roll
# the affected workloads afterward:
#   kubectl rollout restart deployment/bifrost -n <namespace>
#   kubectl rollout restart deployment -n <namespace> -l app.kubernetes.io/name=straiker-ascend
phase_ai_provider_secrets() {
  if [[ ",${PRODUCTS_OPT}," != *",ascend,"* ]]; then
    log "'ascend' not selected — skipping AI provider secrets (bifrost has nothing to route for it)."
    return
  fi

  require_command kubectl

  if ! kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    mark_phase_blocked "Secret '${SHARED_SECRETS_NAME}' doesn't exist yet. Run phase 'shared-secrets' first."
    return
  fi

  ensure_k8s_ready_for_charts || return

  case "${AI_PROVIDER_MODE}" in
    own-keys)
      [[ -n "${AI_OPENAI_KEY}" ]] && patch_shared_secret "SYS__OPENAI_API_KEY" "${AI_OPENAI_KEY}"
      [[ -n "${AI_ANTHROPIC_KEY}" ]] && patch_shared_secret "SYS__ANTHROPIC_API_KEY" "${AI_ANTHROPIC_KEY}"
      [[ -n "${AI_XAI_KEY}" ]] && patch_shared_secret "SYS__XAI_API_KEY" "${AI_XAI_KEY}"
      if [[ -n "${AI_OPENAI_KEY}" || -n "${AI_ANTHROPIC_KEY}" || -n "${AI_XAI_KEY}" ]]; then
        log "Stored provider API key(s) in '${SHARED_SECRETS_NAME}' for bifrost."
      else
        log "No new own-keys provider key to store (already present in '${SHARED_SECRETS_NAME}', or none captured)."
      fi
      ;;
    bedrock)
      if [[ -n "${AI_BEDROCK_ACCESS_KEY}" && -n "${AI_BEDROCK_SECRET_KEY}" ]]; then
        patch_shared_secret "SYS__AWS_ACCESS_KEY_ID" "${AI_BEDROCK_ACCESS_KEY}"
        patch_shared_secret "SYS__AWS_SECRET_ACCESS_KEY" "${AI_BEDROCK_SECRET_KEY}"
        log "Stored Bedrock credentials in '${SHARED_SECRETS_NAME}' for bifrost (region: ${AI_BEDROCK_REGION})."
      else
        log "No new Bedrock credentials to store (already present in '${SHARED_SECRETS_NAME}', or none captured)."
      fi
      ;;
    trial-key)
      if [[ -n "${AI_TRIAL_VIRTUAL_KEY}" ]]; then
        patch_shared_secret "BIFROST_API_KEY" "${AI_TRIAL_VIRTUAL_KEY}"
        log "Stored the trial virtual key in '${SHARED_SECRETS_NAME}' for straiker-ascend."
      else
        log "No new trial virtual key to store (already present in '${SHARED_SECRETS_NAME}', or none captured)."
      fi
      ;;
    *)
      mark_phase_blocked "Unknown ai_provider_mode '${AI_PROVIDER_MODE}' in state. Remove the 'ai_provider_mode' key from ~/.straiker/install.json's metadata and re-run to be re-prompted."
      return
      ;;
  esac
}

# Application layer — frontend/bifrost/dex/caddy (charts/straiker-core,
# a standalone chart). Runs after straiker-system since frontend connects
# to that chart's postgres/opensearch directly (see straiker-core's
# global.infraNamespace default).
phase_straiker_core() {
  require_command helm
  require_command kubectl

  # Precondition, not just ordering: frontend connects straight to
  # straiker-system's postgres/opensearch, so a straiker-system that
  # merely ran earlier isn't enough — it must currently be healthy. Checking
  # the live release status here (rather than trusting this phase's own
  # recorded state, which can go stale if a prior run died mid-phase without
  # a chance to update it) catches a straiker-system that failed, was
  # never actually installed, or was torn down since.
  local infra_status
  infra_status="$(helm status "${INFRA_RELEASE}" -n "${INFRA_NAMESPACE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
  if [[ "${infra_status}" != "deployed" ]]; then
    mark_phase_blocked "Release '${INFRA_RELEASE}' in namespace '${INFRA_NAMESPACE}' is not healthy (status: '${infra_status:-not installed}'). straiker-core needs its postgres/opensearch — fix and re-run 'straiker-system' first (--phase straiker-system --rerun-phase)."
    return
  fi

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
  # and populate the ECR mirror — bifrost/frontend/dex/caddy all need
  # this, same as straiker-system. straiker-core is a standalone chart
  # (not a subchart), so these are just its own top-level values — no
  # "straiker-core." prefix needed.
  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  if [[ -n "${ecr_registry}" ]]; then
    local ecr_registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"
    log "Pointing global.dockerRegistry at the ECR mirror (${ecr_registry_prefixed})."
    cmd+=(--set "global.dockerRegistry=${ecr_registry_prefixed}")
  fi

  # Matches charts/straiker-system's own namespace (both default to
  # INFRA_NAMESPACE) — override both together if that chart is ever installed
  # somewhere else.
  cmd+=(--set "global.infraNamespace=${INFRA_NAMESPACE}")

  # phase_shared_secrets (runs earlier) creates this Secret/key — wire the
  # chart's own (empty-by-default) references at it so argus's settings-sync
  # calls into /internal_api/* actually authenticate. straiker-core is an
  # umbrella chart with straiker-frontend as a subchart (see its Chart.yaml
  # dependencies) — overriding a subchart's own values from the parent
  # release needs the "<subchart-name>." prefix, unlike global.* above
  # (which every subchart picks up automatically via Helm's global
  # mechanism); a bare "frontend.internalApiKey...=" here would silently
  # create an unused top-level key on the parent instead of reaching the
  # subchart's values at all. Unconditional, unlike argusEndpoint below: the
  # key exists regardless of which products are selected, so there's no
  # reason to omit it.
  cmd+=(--set "straiker-frontend.frontend.internalApiKey.secretName=${SHARED_SECRETS_NAME}")
  cmd+=(--set "straiker-frontend.frontend.internalApiKey.secretKey=INTERNAL_API_KEY")

  # Only set when 'defend' is actually selected — straiker-defend's Service
  # won't exist otherwise, and the chart already omits this env var entirely
  # when unset rather than pointing at a URL that resolves to nothing.
  if [[ ",${PRODUCTS_OPT}," == *",defend,"* ]]; then
    cmd+=(--set "straiker-frontend.frontend.argusEndpoint=http://${DEFEND_RELEASE}.${INFRA_NAMESPACE}.svc.cluster.local")
  fi

  # Same reasoning for 'ascend' — charts/straiker-ascend's control-plane
  # Service (frontend calls this to start/pause/stream assessment runs).
  # IRIS_ADMIN_API_KEY is unconditional like internalApiKey above (it's
  # generated in phase_shared_secrets regardless of product selection), only
  # the endpoint is gated.
  cmd+=(--set "straiker-frontend.frontend.irisControlPlaneAdminApiKey.secretName=${SHARED_SECRETS_NAME}")
  cmd+=(--set "straiker-frontend.frontend.irisControlPlaneAdminApiKey.secretKey=IRIS_ADMIN_API_KEY")
  if [[ ",${PRODUCTS_OPT}," == *",ascend,"* ]]; then
    cmd+=(--set "straiker-frontend.frontend.irisControlPlaneAdminEndpoint=http://${ASCEND_RELEASE}-control-plane.${INFRA_NAMESPACE}.svc.cluster.local")
  fi

  # AI provider mode (see AI_PROVIDER_MODE's declaration + phase_ai_provider_secrets).
  # bedrock needs its region set explicitly on bifrost's own subchart values.
  # own-keys needs no extra bifrost values — its provider keys are already in
  # straiker-secrets, which bifrost's chart reads unconditionally either way.
  # trial-key needs no bifrost changes at all — it bypasses this in-cluster
  # bifrost entirely via straiker-ascend's own bifrost.baseUrl override,
  # wired in phase_straiker_ascend instead.
  if [[ "${AI_PROVIDER_MODE}" == "bedrock" ]]; then
    local bedrock_region
    bedrock_region="$(get_metadata "bedrock_region")"
    if [[ -n "${bedrock_region}" ]]; then
      cmd+=(--set "straiker-bifrost.bedrock.region=${bedrock_region}")
    fi
  fi

  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  "${cmd[@]}"
}

# Product -> inference model mapping (Defend's argus needs 4 backends, Ascend's
# iris needs 1). Derived from PRODUCTS_OPT fresh on every call rather than
# persisted separately, so it can never drift from the actual product
# selection captured earlier.
inference_models_for_products() {
  local models=()
  if [[ ",${PRODUCTS_OPT}," == *",defend,"* ]]; then
    # vision/wanda temporarily disabled (2026-08-16) -- re-add "vision"
    # "wanda" here once ready. Argus's SYS__LLM_ENDPOINTS__VISION/
    # IMAGE_DETECTION will just error for the categories that route to
    # them until then.
    models+=("antman" "hulk" "quicksilver" "thor")
  fi
  if [[ ",${PRODUCTS_OPT}," == *",ascend,"* ]]; then
    models+=("thanos")
  fi
  printf '%s\n' "${models[@]+"${models[@]}"}"
}

# One Helm release per model (matches charts/straiker-inference's own "one
# release per model" design — release name IS the model name) rather than one
# release covering all of them, so a GPU-capacity problem with one model
# doesn't block the others from installing, and each can be checked
# independently via `helm status <model>`.
phase_straiker_inference() {
  require_command helm
  require_command kubectl

  # Portable bash 3.2 equivalent of `mapfile` — this repo avoids bash 4+
  # builtins since macOS ships a frozen bash 3.2 (Apple stopped updating it
  # over the GPLv3 license change), and this installer is tested there too.
  local models=()
  local model_line
  while IFS= read -r model_line; do
    [[ -n "${model_line}" ]] && models+=("${model_line}")
  done < <(inference_models_for_products)
  if [[ ${#models[@]} -eq 0 ]]; then
    log "No selected product needs a GPU inference model — skipping."
    return
  fi

  local ecr_registry models_bucket
  ecr_registry="$(get_metadata "ecr_registry")"
  models_bucket="$(get_metadata "models_bucket")"
  if [[ -z "${ecr_registry}" || -z "${models_bucket}" ]]; then
    mark_phase_blocked "Missing ecr_registry/models_bucket from install state. Run phase 'aws-artifacts' first."
    return
  fi

  ensure_k8s_ready_for_charts || return

  # Shared across all per-model releases below — EKS Pod Identity binds one
  # IAM role to exactly one (namespace, ServiceAccount name) pair (set up by
  # phase_aws_artifacts), so every model must reference the SAME
  # ServiceAccount rather than each owning its own. charts/straiker-inference
  # deliberately does not create this itself: if it did, only the first of
  # the 7 releases could ever succeed — every later one would fail with a
  # Helm ownership conflict ("cannot be imported into the current release")
  # since Helm refuses to let two releases both claim the same resource.
  kubectl create serviceaccount "${INFERENCE_SERVICE_ACCOUNT}" \
    -n "${INFRA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # GKE only — binds this KSA to the GCP SA via Workload Identity (EKS Pod
  # Identity needs no such annotation, so this is a no-op there).
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    local workload_gsa
    workload_gsa="$(get_metadata "workload_service_account_email")"
    if [[ -n "${workload_gsa}" ]]; then
      kubectl annotate serviceaccount "${INFERENCE_SERVICE_ACCOUNT}" -n "${INFRA_NAMESPACE}" \
        "iam.gke.io/gcp-service-account=${workload_gsa}" --overwrite >/dev/null
    fi
  fi

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  # Same "<registry>/<prefix>" reasoning as phase_straiker_core/straiker_system.
  local ecr_registry_prefixed
  ecr_registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"

  # Installed in batches of INFERENCE_CONCURRENCY rather than one at a time
  # (each model's GPU cold-start can take a while, and they're independent
  # releases with no reason to serialize) or all at once (which would fire
  # every model's GPU node request simultaneously, risking the account's
  # actual GPU quota/capacity limits). Bash 3.2 (this repo's floor — see the
  # `mapfile` note above) has no `wait -n`, so a batch waits for its slowest
  # member before the next batch starts rather than refilling slots as they
  # free up — simpler to get right than a true worker pool, at the cost of
  # some idle concurrency within a batch.
  local failed=()
  local model release
  local total=${#models[@]}
  local i=0
  while (( i < total )); do
    local batch_models=()
    local batch_pids=()
    local batch_logs=()

    local j=0
    while (( j < INFERENCE_CONCURRENCY && i < total )); do
      model="${models[i]}"
      # "inference-<model>" — matches Straiker's own production release naming
      # and, since .Values.modelProfile (not .Release.Name) drives resource
      # names in this chart (see straiker-inference.fullname), keeps the K8s
      # resource names consistent with the release name rather than bare.
      release="inference-${model}"
      log "Installing inference model '${model}' as release '${release}'..."
      local cmd=(
        helm upgrade --install "${release}" "${HELM_REPO_NAME}/${INFERENCE_CHART_NAME}"
        --namespace "${INFRA_NAMESPACE}"
        --create-namespace
        --set "modelProfile=${model}"
        --set "global.dockerRegistry=${ecr_registry_prefixed}"
        --set "global.modelBucket=$(model_bucket_uri "${models_bucket}")"
        --wait
        --timeout "${HELM_TIMEOUT}"
      )
      if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
        cmd+=(--set "cloudProvider=gke")
      fi
      if [[ -n "${CHART_VERSION}" ]]; then
        cmd+=(--version "${CHART_VERSION}")
      fi

      local logfile
      logfile="$(mktemp)"
      ( "${cmd[@]}" ) >"${logfile}" 2>&1 &
      batch_models+=("${model}")
      batch_pids+=("$!")
      batch_logs+=("${logfile}")

      i=$((i + 1))
      j=$((j + 1))
    done

    # Collect this batch's results before starting the next one. Each
    # backgrounded helm run's output was captured to its own logfile (rather
    # than left to inherit stdout/stderr directly) so concurrent runs don't
    # interleave into unreadable output — replayed here, one model at a time.
    local k=0
    while (( k < ${#batch_pids[@]} )); do
      if wait "${batch_pids[k]}"; then
        log "Inference model '${batch_models[k]}' installed successfully."
      else
        failed+=("${batch_models[k]}")
        log "Inference model '${batch_models[k]}' FAILED."
      fi
      echo "----- ${batch_models[k]} output -----"
      cat "${batch_logs[k]}"
      echo "----- end ${batch_models[k]} output -----"
      rm -f "${batch_logs[k]}"
      k=$((k + 1))
    done
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    mark_phase_blocked "Inference model(s) failed to install: ${failed[*]}. Each model is its own Helm release named 'inference-<model>' — check GPU node/capacity availability for the failed one(s), then re-run --phase straiker-inference --rerun-phase (already-succeeded models are just re-verified, not disrupted)."
    return
  fi
}

# Argus (Straiker's "Defend" product) — only when "defend" is selected.
# Depends on straiker-system (Redis/OpenSearch/Benthos, shared NodePool) and
# straiker-inference's per-model releases (SYS__LLM_ENDPOINTS__* targets)
# already being up; checks straiker-system's live release status the same way
# phase_straiker_core does, since a phase that merely ran earlier isn't proof
# it's still healthy.
phase_straiker_defend() {
  if [[ ",${PRODUCTS_OPT}," != *",defend,"* ]]; then
    log "'defend' not selected — skipping straiker-defend."
    return
  fi

  require_command helm
  require_command kubectl

  local infra_status
  infra_status="$(helm status "${INFRA_RELEASE}" -n "${INFRA_NAMESPACE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
  if [[ "${infra_status}" != "deployed" ]]; then
    mark_phase_blocked "Release '${INFRA_RELEASE}' in namespace '${INFRA_NAMESPACE}' is not healthy (status: '${infra_status:-not installed}'). straiker-defend needs its Redis/OpenSearch/Benthos — fix and re-run 'straiker-system' first (--phase straiker-system --rerun-phase)."
    return
  fi

  local ecr_registry models_bucket
  ecr_registry="$(get_metadata "ecr_registry")"
  models_bucket="$(get_metadata "models_bucket")"
  if [[ -z "${ecr_registry}" || -z "${models_bucket}" ]]; then
    mark_phase_blocked "Missing ecr_registry/models_bucket from install state. Run phase 'aws-artifacts' first."
    return
  fi

  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  local ecr_registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"
  local cmd=(
    helm upgrade --install "${DEFEND_RELEASE}" "${HELM_REPO_NAME}/${DEFEND_CHART_NAME}"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --set "global.dockerRegistry=${ecr_registry_prefixed}"
    --set "global.modelBucket=$(model_bucket_uri "${models_bucket}")"
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    cmd+=(--set "cloudProvider=gke")
    local workload_gsa
    workload_gsa="$(get_metadata "workload_service_account_email")"
    if [[ -n "${workload_gsa}" ]]; then
      cmd+=(--set "gcpServiceAccountEmail=${workload_gsa}")
    fi
  fi
  if [[ -n "${CHART_VERSION}" ]]; then
    cmd+=(--version "${CHART_VERSION}")
  fi
  "${cmd[@]}"
}

# Iris automated red-teaming engine (Straiker's "Ascend" product) — only
# when "ascend" is selected. Runs after straiker-core (shared Postgres via
# straiker-system + frontend's admin-API callback) and straiker-inference
# (needs inference-thanos already resolvable).
phase_straiker_ascend() {
  if [[ ",${PRODUCTS_OPT}," != *",ascend,"* ]]; then
    log "'ascend' not selected — skipping straiker-ascend."
    return
  fi

  require_command helm
  require_command kubectl

  local core_status
  core_status="$(helm status "${APP_RELEASE}" -n "${INFRA_NAMESPACE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
  if [[ "${core_status}" != "deployed" ]]; then
    mark_phase_blocked "Release '${APP_RELEASE}' in namespace '${INFRA_NAMESPACE}' is not healthy (status: '${core_status:-not installed}'). straiker-ascend needs straiker-system's shared Postgres and straiker-core's frontend — fix and re-run 'straiker-core' first (--phase straiker-core --rerun-phase)."
    return
  fi

  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  if [[ -z "${ecr_registry}" ]]; then
    mark_phase_blocked "Missing ecr_registry from install state. Run phase 'aws-artifacts' first."
    return
  fi

  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  local cmd=(
    helm upgrade --install "${ASCEND_RELEASE}" "${HELM_REPO_NAME}/${ASCEND_CHART_NAME}"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --set "global.dockerRegistry=$(docker_registry_with_prefix "${ecr_registry}")"
    --set "db.host=postgres.${INFRA_NAMESPACE}.svc.cluster.local"
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  if [[ -n "${CHART_VERSION}" ]]; then
    cmd+=(--version "${CHART_VERSION}")
  fi

  # trial-key routes straiker-ascend's own bifrost calls straight at
  # Straiker's hosted gateway instead of the in-cluster bifrost -- base URL
  # fetched from the artifact broker alongside the virtual key itself (see
  # AI_TRIAL_BIFROST_BASE_URL's declaration + phase_ai_provider_secrets,
  # which stores the matching BIFROST_API_KEY). own-keys/bedrock need no
  # override here — the default (empty) resolves to the in-cluster bifrost
  # Service, which phase_straiker_core/phase_ai_provider_secrets already
  # configured.
  if [[ "${AI_PROVIDER_MODE}" == "trial-key" ]]; then
    cmd+=(--set "bifrost.baseUrl=${AI_TRIAL_BIFROST_BASE_URL}")
  fi

  "${cmd[@]}"
}

# Thin TLS edge (charts/straiker-edge) — always runs (frontend needs it
# regardless of product selection). Depends only on straiker-core's frontend
# Service existing; doesn't check straiker-defend's status since its
# defend-api route is allowed to 502 until that's installed.
phase_straiker_edge() {
  require_command helm
  require_command kubectl

  local core_status
  core_status="$(helm status "${APP_RELEASE}" -n "${INFRA_NAMESPACE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
  if [[ "${core_status}" != "deployed" ]]; then
    mark_phase_blocked "Release '${APP_RELEASE}' in namespace '${INFRA_NAMESPACE}' is not healthy (status: '${core_status:-not installed}'). straiker-edge routes to its frontend Service — fix and re-run 'straiker-core' first (--phase straiker-core --rerun-phase)."
    return
  fi

  require_file_inputs "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"
  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  local cmd=(
    helm upgrade --install "${EDGE_RELEASE}" "${HELM_REPO_NAME}/${EDGE_CHART_NAME}"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  if [[ -n "${ecr_registry}" ]]; then
    cmd+=(--set "global.dockerRegistry=$(docker_registry_with_prefix "${ecr_registry}")")
  fi
  if [[ -n "${CHART_VERSION}" ]]; then
    cmd+=(--version "${CHART_VERSION}")
  fi

  # Same appDomain as straiker-core, and via the same -f files, so a
  # customer's custom appDomain override (if in a values file used for both)
  # applies consistently to both charts' independently-computed hostnames.
  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  "${cmd[@]}"
}

# Called unconditionally at the end of a successful main() run — not just
# right after phase_straiker_edge actually executes, since that phase gets
# skipped entirely on a re-run once already marked done. Reads live cluster
# state (charts/straiker-edge's own ConfigMap) rather than assuming anything
# was just installed, so it prints correctly whether this run did real work
# or everything was already up from a previous one.
show_access_info() {
  local app_addr app_host app_port
  app_addr="$(kubectl -n "${INFRA_NAMESPACE}" get configmap straiker-edge-config -o jsonpath='{.data.Caddyfile}' 2>/dev/null | grep -o 'app\.[^ {]*' | head -1 || true)"
  if [[ -n "${app_addr}" ]]; then
    app_host="${app_addr%%:*}"
    app_port="${app_addr##*:}"
    log ""
    log "Straiker is installed. To reach it from your machine:"
    log "  1. echo '127.0.0.1 ${app_host}' | sudo tee -a /etc/hosts"
    log "  2. kubectl -n ${INFRA_NAMESPACE} port-forward svc/straiker-edge ${app_port}:${app_port}"
    log "  3. open https://${app_addr}/ (a self-signed cert warning is expected)"
  fi

  # Documentation only — not run automatically. The API key is a
  # per-application credential (seeded into the customer's own tenant via
  # settings-sync), so there's no value the installer itself could fill in
  # here; add it to /etc/hosts the same way as app_host above if you want to
  # actually run this.
  if [[ ",${PRODUCTS_OPT}," == *",defend,"* ]]; then
    local defend_addr
    defend_addr="$(kubectl -n "${INFRA_NAMESPACE}" get configmap straiker-edge-config -o jsonpath='{.data.Caddyfile}' 2>/dev/null | grep -o 'defend\.[^ {]*' | head -1 || true)"
    if [[ -n "${defend_addr}" ]]; then
      log ""
      log "Smoke test the Defend API (needs one of your application's API keys):"
      log "  curl -sk -X POST https://${defend_addr}/api/v1/detect \\"
      log "    -H \"Authorization: Bearer <your-application-api-key>\" \\"
      log "    -H \"Content-Type: application/json\" \\"
      log "    -H \"Straiker-Debug: true\" \\"
      log "    -d '{\"prompt\":\"What is the capital of France?\"}' | jq"
    fi
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
# Anything unrecognized is a hard error (typo protection) rather than being
# silently ignored.
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
      *)
        echo "ERROR: Unknown product '${token}'. Valid choices: ascend, defend." >&2
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

  # Cloud provider — first-run-only (see the CLOUD_PROVIDER declaration up
  # top). Once "cloud_provider_set" exists, the stored value always wins;
  # --cloud-provider on this invocation is simply overwritten and never
  # re-persisted differently.
  if [[ "$(get_metadata "cloud_provider_set")" == "true" ]]; then
    CLOUD_PROVIDER="$(get_metadata "cloud_provider")"
  else
    set_metadata "cloud_provider" "${CLOUD_PROVIDER}"
    set_metadata "cloud_provider_set" "true"
  fi

  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    # GCP project — mandatory, same "still empty means still needs resolving"
    # pattern as AWS region below.
    [[ -z "${GCP_PROJECT_OPT}" ]] && GCP_PROJECT_OPT="$(get_metadata "gcp_project")"
    resolve_gcp_project
    if [[ -z "${GCP_PROJECT_OPT}" ]]; then
      GCP_PROJECT_OPT="$(prompt_line 'GCP project ID (required): ' || true)"
    fi
    if [[ -z "${GCP_PROJECT_OPT}" ]]; then
      echo "ERROR: GCP project is required. Use --gcp-project, GOOGLE_CLOUD_PROJECT, or configure gcloud." >&2
      exit 1
    fi
    set_metadata "gcp_project" "${GCP_PROJECT_OPT}"

    # GCP region — mandatory, same pattern.
    [[ -z "${GCP_REGION}" ]] && GCP_REGION="$(get_metadata "gcp_region")"
    resolve_gcp_region
    if [[ -z "${GCP_REGION}" ]]; then
      GCP_REGION="$(prompt_line 'GCP region (required): ' || true)"
    fi
    if [[ -z "${GCP_REGION}" ]]; then
      echo "ERROR: GCP region is required. Use --gcp-region, or configure gcloud's compute/region." >&2
      exit 1
    fi
    set_metadata "gcp_region" "${GCP_REGION}"
  else
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
  fi

  # Install mode — false is both the default and a valid deliberate answer
  # ("use an existing cluster"), so it needs the same "_set" tracking as
  # profile above rather than relying on its own truthiness. Applies to
  # either cloud provider — --install-eks provisions an EKS or GKE cluster
  # depending on cloud_provider above (see phase_eks_cluster).
  if [[ "${INSTALL_EKS_EXPLICIT}" != true ]]; then
    if [[ "$(get_metadata "install_eks_set")" == "true" ]]; then
      [[ "$(get_metadata "install_eks")" == "true" ]] && INSTALL_EKS=true
    else
      local mode
      mode="$(prompt_line 'Provision a new cluster, or use an existing one? [new/existing] (default: existing): ' || true)"
      [[ "${mode}" == "new" ]] && INSTALL_EKS=true
    fi
  fi
  set_metadata "install_eks" "${INSTALL_EKS}"
  set_metadata "install_eks_set" "true"

  # Provision strategy — only meaningful when this installer is provisioning
  # the cluster itself; bring-your-own-cluster installs skip this entirely
  # (nothing here to size). First-run-only like cloud_provider above: once
  # persisted, always wins regardless of what --provision-strategy says on a
  # later invocation.
  if [[ "${INSTALL_EKS}" == true ]]; then
    if [[ "$(get_metadata "provision_strategy_set")" == "true" ]]; then
      PROVISION_STRATEGY="$(get_metadata "provision_strategy")"
    else
      if [[ "${PROVISION_STRATEGY_EXPLICIT}" != true ]]; then
        cat >&2 <<'EOF'

How much infrastructure should this install provision?
  1) min — single-AZ/zone, cheapest, PoC only (an AZ/zone outage takes the
           whole service down; see terraform/aws/eks's provision_strategy
           variable for exactly what this pins to one AZ/zone) (default)
  2) ha  — multi-AZ/zone
  3) max — extra node/AZ headroom for maximum resilience
EOF
        local strategy_answer
        strategy_answer="$(prompt_line 'Provision strategy [min/ha/max] (default: min): ' || true)"
        case "${strategy_answer}" in
          ha) PROVISION_STRATEGY=ha ;;
          max) PROVISION_STRATEGY=max ;;
          min|"") PROVISION_STRATEGY=min ;;
          *)
            echo "ERROR: provision strategy must be 'min', 'ha', or 'max', got '${strategy_answer}'." >&2
            exit 1
            ;;
        esac
      fi
      set_metadata "provision_strategy" "${PROVISION_STRATEGY}"
      set_metadata "provision_strategy_set" "true"
    fi
  fi

  # Products — mandatory, at least one; "still empty" doubles as "still needs
  # resolving," same as region above.
  [[ -z "${PRODUCTS_OPT}" ]] && PRODUCTS_OPT="$(get_metadata "products")"
  if [[ -z "${PRODUCTS_OPT}" ]]; then
    cat >&2 <<'EOF'

Which Straiker products should this install provision infrastructure for?
Select at least one.
  1) Ascend
  2) Defend
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

  # Straiker customer identity — mandatory, and captured before the AI
  # provider mode section below since trial-key mode needs it already
  # resolved.
  if [[ -z "${STRAIKER_CUSTOMER_NAME}" ]]; then
    STRAIKER_CUSTOMER_NAME="$(get_metadata "straiker_customer_name")"
  fi
  if [[ -z "${STRAIKER_CUSTOMER_KEY}" ]]; then
    STRAIKER_CUSTOMER_KEY="$(get_metadata "straiker_customer_key")"
  fi
  if [[ -z "${STRAIKER_CUSTOMER_NAME}" || -z "${STRAIKER_CUSTOMER_KEY}" ]]; then
    cat >&2 <<'EOF'

Straiker provides a per-customer name and API key (contact your Straiker
rep if you don't have them).
EOF
    [[ -z "${STRAIKER_CUSTOMER_NAME}" ]] && STRAIKER_CUSTOMER_NAME="$(prompt_line 'Straiker customer name (required): ' || true)"
    [[ -z "${STRAIKER_CUSTOMER_KEY}" ]] && STRAIKER_CUSTOMER_KEY="$(prompt_line 'Straiker customer key (required): ' || true)"
    if [[ -z "${STRAIKER_CUSTOMER_NAME}" || -z "${STRAIKER_CUSTOMER_KEY}" ]]; then
      echo "ERROR: Both a Straiker customer name and key are required (--straiker-customer-name/--straiker-customer-key)." >&2
      exit 1
    fi
  fi
  set_metadata "straiker_customer_name" "${STRAIKER_CUSTOMER_NAME}"
  set_metadata "straiker_customer_key" "${STRAIKER_CUSTOMER_KEY}"

  # AI provider mode + credential(s) for Ascend's recon-agent — only asked
  # when 'ascend' is selected. See AI_PROVIDER_MODE's declaration up top for
  # why mode selection follows PRODUCTS_OPT's "explicit flag overrides
  # persisted value" pattern rather than CLOUD_PROVIDER/PROVISION_STRATEGY's
  # hard first-run-only lock. Unlike those two, the actual credential VALUE
  # is also collected right here (not deferred to the later
  # 'ai-provider-secrets' phase) -- picking a mode should have a visible next
  # step immediately, not silence until a much-later phase happens to run.
  # phase_ai_provider_secrets just writes whatever got captured here, once
  # the cluster/Secret actually exist. Best-effort checks the live Secret
  # first (INFRA_NAMESPACE is already resolved by this point) to avoid
  # re-prompting on a later run once a key's already stored; if the cluster
  # isn't reachable yet (e.g. a from-scratch --install-eks run), that check
  # just fails silently via secret_key_exists and this prompts anyway, same
  # as a first-ever run.
  if [[ ",${PRODUCTS_OPT}," == *",ascend,"* ]]; then
    if [[ -z "${AI_PROVIDER_MODE}" ]]; then
      AI_PROVIDER_MODE="$(get_metadata "ai_provider_mode")"
    fi
    if [[ -z "${AI_PROVIDER_MODE}" ]]; then
      cat >&2 <<'EOF'

Ascend's automated red-teaming agent needs its own AI provider access
(separate from whatever target system/model is actually being tested). Pick
how it should reach one:
  1) own-keys  — bring your own OpenAI/Anthropic/xAI API key(s). Already
                 exported OPENAI_API_KEY/ANTHROPIC_API_KEY/XAI_API_KEY in
                 this shell are picked up automatically, no prompt needed.
  2) bedrock   — use AWS Bedrock (needs an IAM identity with bedrock:InvokeModel
                 — this installer will print the exact AWS CLI commands to set
                 that up, then ask for the resulting access key)
  3) trial-key — use a Straiker-hosted temporary virtual key (up to 30 days,
                 PoC/trial use only), fetched automatically using your
                 Straiker customer name/key — ask your Straiker contact to
                 enable trial access for your account first.
EOF
      local ai_mode_answer
      ai_mode_answer="$(prompt_line 'AI provider mode [own-keys/bedrock/trial-key] (default: own-keys): ' || true)"
      case "${ai_mode_answer}" in
        1|own-keys|"") AI_PROVIDER_MODE=own-keys ;;
        2|bedrock) AI_PROVIDER_MODE=bedrock ;;
        3|trial-key) AI_PROVIDER_MODE=trial-key ;;
        *)
          echo "ERROR: AI provider mode must be 'own-keys', 'bedrock', or 'trial-key', got '${ai_mode_answer}'. Use --ai-provider-mode <own-keys|bedrock|trial-key>." >&2
          exit 1
          ;;
      esac
    fi
    set_metadata "ai_provider_mode" "${AI_PROVIDER_MODE}"

    case "${AI_PROVIDER_MODE}" in
      own-keys)
        if secret_key_exists "SYS__OPENAI_API_KEY" || secret_key_exists "SYS__ANTHROPIC_API_KEY" || secret_key_exists "SYS__XAI_API_KEY"; then
          log "At least one own-keys provider key is already present in '${SHARED_SECRETS_NAME}' — leaving as-is. Use 'kubectl patch secret ${SHARED_SECRETS_NAME} -n ${INFRA_NAMESPACE} --type=merge -p ...' directly to change/add one."
        else
          cat >&2 <<'EOF'

Enter API keys for whichever LLM providers Ascend's agent should use (leave
any blank to skip that provider entirely — bifrost just won't route to it).
At least one is required.

Checking this shell's environment for OPENAI_API_KEY/ANTHROPIC_API_KEY/
XAI_API_KEY — any that are already set are used automatically, with no
prompt; you'll only be asked for the ones that aren't:
EOF
          local env_var
          for env_var in OPENAI_API_KEY ANTHROPIC_API_KEY XAI_API_KEY; do
            if [[ -n "${!env_var:-}" ]]; then
              echo "  ${env_var} is set — will be used." >&2
            else
              echo "  ${env_var} is not set — you'll be prompted for it." >&2
            fi
          done
          AI_OPENAI_KEY="${OPENAI_API_KEY:-}"
          [[ -z "${AI_OPENAI_KEY}" ]] && AI_OPENAI_KEY="$(prompt_line 'OpenAI API key (blank to skip): ' || true)"
          AI_ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
          [[ -z "${AI_ANTHROPIC_KEY}" ]] && AI_ANTHROPIC_KEY="$(prompt_line 'Anthropic API key (blank to skip): ' || true)"
          AI_XAI_KEY="${XAI_API_KEY:-}"
          [[ -z "${AI_XAI_KEY}" ]] && AI_XAI_KEY="$(prompt_line 'xAI API key (blank to skip): ' || true)"
          if [[ -z "${AI_OPENAI_KEY}" && -z "${AI_ANTHROPIC_KEY}" && -z "${AI_XAI_KEY}" ]]; then
            echo "ERROR: 'own-keys' mode needs at least one provider API key. Set OPENAI_API_KEY/ANTHROPIC_API_KEY/XAI_API_KEY in this shell, or re-run and answer the prompt." >&2
            exit 1
          fi
        fi
        ;;
      bedrock)
        if secret_key_exists "SYS__AWS_ACCESS_KEY_ID"; then
          log "Bedrock credentials are already present in '${SHARED_SECRETS_NAME}' — leaving as-is."
        else
          local default_region="${AWS_REGION:-us-east-1}"
          cat >&2 <<EOF

Bedrock needs an IAM identity with bedrock:InvokeModel/InvokeModelWithResponseStream
permission. If you don't already have one, create it with:

  aws iam create-user --user-name straiker-ascend-bedrock
  aws iam put-user-policy --user-name straiker-ascend-bedrock \\
    --policy-name straiker-ascend-bedrock-invoke \\
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],"Resource":"arn:aws:bedrock:${default_region}::foundation-model/*"}]}'
  aws iam create-access-key --user-name straiker-ascend-bedrock

The last command prints an AccessKeyId/SecretAccessKey — enter them below.
You'll also need to request access to whichever foundation models you want
under Bedrock > Model access in the AWS Console (per-model, one-time,
console-only — no CLI equivalent).

EOF
          AI_BEDROCK_ACCESS_KEY="$(prompt_line 'AWS access key ID (required): ' || true)"
          AI_BEDROCK_SECRET_KEY="$(prompt_line 'AWS secret access key (required): ' || true)"
          if [[ -z "${AI_BEDROCK_ACCESS_KEY}" || -z "${AI_BEDROCK_SECRET_KEY}" ]]; then
            echo "ERROR: 'bedrock' mode needs both an AWS access key ID and secret access key. Re-run and provide both." >&2
            exit 1
          fi
          AI_BEDROCK_REGION="$(prompt_line "Bedrock region (default: ${default_region}): " || true)"
          [[ -z "${AI_BEDROCK_REGION}" ]] && AI_BEDROCK_REGION="${default_region}"
          set_metadata "bedrock_region" "${AI_BEDROCK_REGION}"
        fi
        ;;
      trial-key)
        # base_url is needed by phase_straiker_ascend on every run, so it's
        # persisted even though the virtual key itself isn't re-fetched once
        # already stored.
        if secret_key_exists "BIFROST_API_KEY"; then
          log "A trial virtual key is already present in '${SHARED_SECRETS_NAME}' — leaving as-is."
          AI_TRIAL_BIFROST_BASE_URL="$(get_metadata "bifrost_trial_base_url")"
        else
          log "Fetching your Bifrost trial virtual key from the artifact broker..."
          local bifrost_trial_response
          bifrost_trial_response="$(curl -sf -H "Authorization: Bearer ${STRAIKER_CUSTOMER_KEY}" -H "X-Customer-Email: $(straiker_customer_email)" "${ARTIFACT_BROKER_BIFROST_TRIAL_URL}" || true)"
          if [[ -z "${bifrost_trial_response}" ]]; then
            echo "ERROR: Could not fetch your Bifrost trial virtual key from the artifact broker (${ARTIFACT_BROKER_BIFROST_TRIAL_URL}). Check network connectivity and that your Straiker contact has provisioned trial access for your account, then re-run." >&2
            exit 1
          fi
          AI_TRIAL_VIRTUAL_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual_key",""))' <<< "${bifrost_trial_response}" 2>/dev/null)"
          AI_TRIAL_BIFROST_BASE_URL="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("base_url",""))' <<< "${bifrost_trial_response}" 2>/dev/null)"
          if [[ -z "${AI_TRIAL_VIRTUAL_KEY}" || -z "${AI_TRIAL_BIFROST_BASE_URL}" ]]; then
            echo "ERROR: Unexpected response from the artifact broker's Bifrost trial endpoint: ${bifrost_trial_response}" >&2
            exit 1
          fi
          set_metadata "bifrost_trial_base_url" "${AI_TRIAL_BIFROST_BASE_URL}"
        fi
        ;;
    esac
  fi

  set_metadata "config_captured" "true"

  log "Config in use: aws_profile=${AWS_PROFILE_OPT:-<default>} aws_region=${AWS_REGION} install_eks=${INSTALL_EKS} cluster_name=${CLUSTER_NAME} namespace=${INFRA_NAMESPACE} products=${PRODUCTS_OPT:-<none>} ai_provider_mode=${AI_PROVIDER_MODE:-<n/a>} straiker_customer_name=${STRAIKER_CUSTOMER_NAME}"
}

require_resource_ack() {
  if [[ "$(get_metadata "resource_ack")" == "true" ]]; then
    return
  fi

  if [[ "${AUTO_YES}" == true ]]; then
    set_metadata "resource_ack" "true"
    return
  fi

  show_cost_estimate >&2

  cat >&2 <<EOF

This installer will create the following resources in your AWS account:
  - An S3 bucket for Terraform state, prefixed 's6r-' (e.g. s6r-onprem-tfstate-<region>-<account-id>)
  - If run with --install-eks: a full EKS stack under the 's6r-onprem' name (VPC, EKS
    cluster, managed node group, Karpenter IAM roles + SQS queue, networking)
  - Mirrored container images pushed to ECR repositories, and ~65 GB of model
    artifacts synced into an S3 bucket (all supported models are synced regardless
    of which products you select above; only the products you pick get deployed
    as running inference services)

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
    straiker-system) phase_straiker_system ;;
    shared-secrets) phase_shared_secrets ;;
    ai-provider-secrets) phase_ai_provider_secrets ;;
    straiker-core) phase_straiker_core ;;
    straiker-inference) phase_straiker_inference ;;
    straiker-defend) phase_straiker_defend ;;
    straiker-ascend) phase_straiker_ascend ;;
    straiker-edge) phase_straiker_edge ;;
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
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    resolve_gcp_region
    resolve_gcp_project
  else
    if [[ -n "${AWS_PROFILE_OPT}" ]]; then
      export AWS_PROFILE="${AWS_PROFILE_OPT}"
    fi
    resolve_aws_region
  fi
  ensure_state_file

  if [[ "${PLAN_ONLY}" == true ]]; then
    show_plan
    exit 0
  fi

  if [[ "${STATUS_ONLY}" == true ]]; then
    show_phase_summary
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
  show_access_info
}

main "$@"
