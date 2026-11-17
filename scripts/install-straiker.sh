#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# OpenTofu's default registry client timeout (10s) is too short for large
# providers (hashicorp/aws in particular) on slow connections — small providers
# finish in time, aws doesn't. Bump both unless the caller already set these.
export TF_REGISTRY_CLIENT_TIMEOUT="${TF_REGISTRY_CLIENT_TIMEOUT:-30}"
export TF_PROVIDER_DOWNLOAD_RETRY="${TF_PROVIDER_DOWNLOAD_RETRY:-5}"

# OpenTofu version installed by --install-tofu. Matches 1-bootstrap.sh.
TOFU_VERSION="1.11.6"
# Installation target — same as 1-bootstrap.sh, works on both CloudShell and
# regular Linux environments without needing sudo.
TOFU_INSTALL_DIR="${HOME}/.local/bin"
TOFU_BIN="${TOFU_INSTALL_DIR}/tofu"

# One state file per install. Default ~/.straiker/install.json; STRAIKER_STATE_FILE points another cluster's install at its
# own file (install-data-layer.sh reads the same variable). A second cluster must not share the first one's file: the
# remembered answers (region, domain, certificates, customer key) would carry over, see check_state_matches_cluster.
STATE_FILE="${STRAIKER_STATE_FILE:-${HOME}/.straiker/install.json}"
STATE_DIR="$(dirname "${STATE_FILE}")"
STATE_SECTION="install"
STATE_SCHEMA_VERSION=1
INSTALLER_BUNDLE_VERSION="${STRAIKER_INSTALLER_BUNDLE_VERSION:-workspace}"
INSTALLER_BUNDLE_HOME="${STRAIKER_INSTALLER_BUNDLE_HOME:-${REPO_ROOT}}"
INSTALLER_BUNDLE_URL="${STRAIKER_INSTALLER_BUNDLE_URL:-}"

TFBE_SRC="${REPO_ROOT}/terraform/aws/tfbe"
EKS_SRC="${REPO_ROOT}/terraform/aws/eks"
ARTIFACTS_SRC="${REPO_ROOT}/terraform/aws/artifacts"
DATA_SRC="${REPO_ROOT}/terraform/aws/data"
# Named EDGE_INFRA_* (not EDGE_*) to avoid colliding with the unrelated
# charts/straiker-edge Helm-chart identifiers (EDGE_RELEASE/EDGE_TYPE/
# EDGE_CHART_NAME) already used throughout this script.
EDGE_INFRA_SRC="${REPO_ROOT}/terraform/aws/edge"
OBSERVABILITY_SRC="${REPO_ROOT}/terraform/aws/observability"

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
DATA_DIR="${TF_WORK_ROOT}/aws/data"
EDGE_INFRA_DIR="${TF_WORK_ROOT}/aws/edge"
OBSERVABILITY_DIR="${TF_WORK_ROOT}/aws/observability"
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

# terraform/aws/edge's alb_controller.tf provisions the IAM role/Pod Identity
# association unconditionally, as part of phase_edge_infra (which only ever
# runs for EDGE_TYPE=alb — see that function's own comment); this installs
# the controller itself via its Helm chart. Lives in terraform/aws/edge
# rather than terraform/aws/eks so it's created regardless of --install-eks
# (bring-your-own-cluster customers choosing edgeType: alb need this too,
# unlike Karpenter above which only manages nodes for clusters this
# installer itself provisioned).
ALB_CONTROLLER_HELM_REPO_NAME="eks"
ALB_CONTROLLER_HELM_REPO_URL="https://aws.github.io/eks-charts"
ALB_CONTROLLER_RELEASE="aws-load-balancer-controller"
ALB_CONTROLLER_NAMESPACE="kube-system"
ALB_CONTROLLER_SERVICE_ACCOUNT="aws-load-balancer-controller"
ALB_CONTROLLER_VERSION="3.5.0"

# terraform/aws/edge's external_dns.tf provisions the IAM role/Pod Identity
# association for edgeType=xalb when Route53 automation is opted into
# (see XALB_ROUTE53_AUTOMATION's declaration); this installs the controller
# itself via its Helm chart, same split as the ALB controller above.
EXTERNAL_DNS_HELM_REPO_NAME="external-dns"
EXTERNAL_DNS_HELM_REPO_URL="https://kubernetes-sigs.github.io/external-dns/"
EXTERNAL_DNS_RELEASE="external-dns"
EXTERNAL_DNS_NAMESPACE="kube-system"
EXTERNAL_DNS_SERVICE_ACCOUNT="external-dns"

# terraform/aws/edge's cert_manager.tf provisions the IAM role/Pod Identity
# association for edgeType=tailscale (see phase_edge_infra); this installs
# cert-manager itself via its Helm chart, same split as the ALB
# controller/ExternalDNS above. Namespace/ServiceAccount defaults match
# jetstack/cert-manager's own chart defaults.
CERT_MANAGER_HELM_REPO_NAME="jetstack"
CERT_MANAGER_HELM_REPO_URL="https://charts.jetstack.io"
CERT_MANAGER_RELEASE="cert-manager"
CERT_MANAGER_NAMESPACE="cert-manager"
CERT_MANAGER_SERVICE_ACCOUNT="cert-manager"
EXTERNAL_DNS_VERSION="1.21.1"

# External Secrets Operator (third-party chart, same as SaaS: ESO syncs Secrets Manager -> K8s Secrets via
# the ClusterSecretStore "aws-sm"). Its AWS access is Pod Identity (role "<cluster>-eso", created by aws-data).
ESO_HELM_REPO_NAME="external-secrets"
ESO_HELM_REPO_URL="https://charts.external-secrets.io"
ESO_RELEASE="external-secrets"
ESO_NAMESPACE="external-secrets"
ESO_SERVICE_ACCOUNT="external-secrets"
ESO_VERSION="0.14.4"
ESO_STORE_NAME="aws-sm"

# --data-layer: Cognito is the frontend's only login. First admin = --admin-email (remembered in install state);
# --reset-admin-password sets that user's Cognito password again from Secrets Manager (recovery).
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

# Phase observability (terraform/aws/observability, EKS only): CloudWatch Observability add-on (Container Insights
# metrics + container logs), alarms and their SNS topic. --alarm-email (repeatable, or comma-separated) subscribes
# addresses to the topic; each must confirm AWS's subscription mail. Remembered (later values are added).
ALARM_EMAILS="${ALARM_EMAILS:-}"
RESET_ADMIN_PASSWORD="${RESET_ADMIN_PASSWORD:-false}"

# --data-layer: also create the AWS backends of the SaaS frontend (full DynamoDB tables, Kinesis audit stream,
# frontend IAM via Pod Identity). Remembered in install state; once on it stays on (--saas-frontend is a one-way switch).
SAAS_FRONTEND="${SAAS_FRONTEND:-false}"

# Platform api-gateway exposure: public (default; internet-facing NLB with TLS), internal (internal NLB, VPC only: ask for it with
# --gateway-exposure internal), none (ClusterIP). Remembered in install state. public needs --gateway-cert-arn (ACM certificate in the
# cluster's region): the gateway is never internet-facing without TLS.
GATEWAY_EXPOSURE="${GATEWAY_EXPOSURE:-}"
GATEWAY_CERT_ARN="${GATEWAY_CERT_ARN:-}"
# The gateway's hostname (e.g. api.customer.com). With it the installer requests the ACM certificate itself (DNS validation, fully
# automatic when a public Route53 zone for the domain is in the same account) and points the name at the load balancer.
GATEWAY_DOMAIN="${GATEWAY_DOMAIN:-}"
GATEWAY_ZONE_ID="${GATEWAY_ZONE_ID:-}"
GATEWAY_ALLOWED_CIDRS="${GATEWAY_ALLOWED_CIDRS:-}"

# --data-layer: the customer's identity provider, federated into the Cognito pool ("Sign in with SSO"). One per install.
#   --sso-type google|facebook|amazon|apple|saml|oidc, plus the values that type needs (see --help).
# Secrets (client secret, Apple private key) come from the environment or a hidden prompt, never argv, and are kept in
# Secrets Manager (<cluster>/cognito/sso-credentials). Everything else is remembered in install state.
SSO_TYPE="${SSO_TYPE:-}"
SSO_NAME="${SSO_NAME:-}"
SSO_SAML_METADATA_URL="${SSO_SAML_METADATA_URL:-}"
SSO_SAML_METADATA_FILE="${SSO_SAML_METADATA_FILE:-}"
SSO_OIDC_ISSUER="${SSO_OIDC_ISSUER:-}"
SSO_CLIENT_ID="${SSO_CLIENT_ID:-${SSO_OIDC_CLIENT_ID:-}}"
SSO_EMAIL_CLAIM="${SSO_EMAIL_CLAIM:-}"
SSO_DOMAINS="${SSO_DOMAINS:-}"
SSO_APPLE_TEAM_ID="${SSO_APPLE_TEAM_ID:-}"
SSO_APPLE_KEY_ID="${SSO_APPLE_KEY_ID:-}"
SSO_APPLE_PRIVATE_KEY_FILE="${SSO_APPLE_PRIVATE_KEY_FILE:-}"
ALLOW_SSO_CHANGE="${ALLOW_SSO_CHANGE:-false}"
SKIP_SSO_PREFLIGHT="${SKIP_SSO_PREFLIGHT:-false}"
ROTATE_ADMIN_PASSWORD="${ROTATE_ADMIN_PASSWORD:-false}"

# --data-layer: Amazon SES sending domain (Cognito mail from no-reply@, connect from notifications@).
# DNS records go into a Route53 zone of this account (found automatically, or created for the domain; then its NS
# records must be delegated from the parent zone). Remembered in install state.
SES_DOMAIN="${SES_DOMAIN:-}"
SES_ROUTE53_ZONE_ID="${SES_ROUTE53_ZONE_ID:-}"
# Alternative: the customer's own SES identity (nothing is created): --ses-identity-arn + --ses-from.
SES_IDENTITY_ARN="${SES_IDENTITY_ARN:-}"
SES_FROM="${SES_FROM:-}"
SES_CONFIGURATION_SET="${SES_CONFIGURATION_SET:-}"
# Aurora roles whose passwords live in Secrets Manager "<cluster>/db/passwords" (charts/straiker-data databases + readers).
DB_PASSWORD_ROLES="foundation registry databridge connect notify frontend iris bifrost grid_cdc"
# ClickHouse users (chart straiker-clickhouse `users`) whose passwords live in "<cluster>/clickhouse/credentials".
CLICKHOUSE_PASSWORD_USERS="admin grid_query_ro grid_ingest grid_purge grid_sync"
# Keys of Secret straiker-secrets (SHARED_SECRETS_NAME) kept in Secrets Manager "<cluster>/platform/shared".
SHARED_SECRET_PROPS="INTERNAL_API_KEY SYS__FOUNDATION_API_KEY VLLM_API_KEY SYS__INFERENCE_API_KEY IRIS_ADMIN_API_KEY BOOTSTRAP_ADMIN_PASSWORD BOOTSTRAP_ADMIN_PASSWORD_HASH"

# Shared provider plugin cache across tfbe and eks (both need hashicorp/aws)
# and across invocations — avoids re-downloading the same large provider.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${TF_WORK_ROOT}/plugin-cache}"
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

# tofu init with one automatic repair: macOS clears old files from /tmp, which can leave the provider cache half-deleted, and init then
# stops with "existing cached package ... does not match". Rebuild the installer's own cache (never one you pointed it at) and retry once.
# The working directory (TF_WORK_ROOT, /tmp/straiker-tf by default) outlives an install, and tofu caches the backend it last
# initialised in <dir>/.terraform. `init -migrate-state -force-copy` would then COPY that other install's state into the new
# backend (a different cluster, prefix, region or account), and the next apply would modify or destroy its resources. So when
# the cached backend differs from the backend.tf about to be used, drop the cache: the state itself lives remotely, nothing is lost.
reset_stale_backend_cache() {
  local dir=$1 cache="${1}/.terraform/terraform.tfstate"
  [[ -f "${cache}" && -f "${dir}/backend.tf" ]] || return 0
  local verdict
  verdict="$(python3 - "${cache}" "${dir}/backend.tf" <<'PY' 2>/dev/null || true
import json, re, sys
try:
    have = json.load(open(sys.argv[1]))["backend"]["config"]
except Exception:
    sys.exit(0)  # no readable cache: nothing to compare
text = open(sys.argv[2]).read()
want = {k: m.group(1) for k in ("bucket", "key", "region") if (m := re.search(r'^\s*%s\s*=\s*"([^"]*)"' % k, text, re.M))}
pick = lambda d: " ".join(f"{k}={d[k]}" for k in sorted(want) if k in d)
if want and pick(have) != pick(want):
    print(f"STALE|{pick(have)}|{pick(want)}")
PY
)"
  if [[ "${verdict}" == STALE\|* ]]; then
    IFS='|' read -r _ have_cfg want_cfg <<<"${verdict}"
    echo "[*] ${dir} was initialised for a different backend (${have_cfg}); clearing its cache so that state is not migrated into this install's backend (${want_cfg})." >&2
    rm -rf "${dir:?}/.terraform"
  fi
}

tofu_init() {
  local dir=$1 out rc=0
  shift
  reset_stale_backend_cache "${dir}"
  out="$(tofu -chdir="${dir}" init "$@" 2>&1)" || rc=$?
  printf '%s\n' "${out}"
  if [[ ${rc} -ne 0 && "${out}" == *"existing cached package"* ]]; then
    if [[ "${TF_PLUGIN_CACHE_DIR}" == "${TF_WORK_ROOT}"/* ]]; then
      echo "[*] The OpenTofu provider cache is inconsistent (${TF_PLUGIN_CACHE_DIR}); rebuilding it and retrying once." >&2
      rm -rf "${TF_PLUGIN_CACHE_DIR:?}"/*
      mkdir -p "${TF_PLUGIN_CACHE_DIR}"
      rc=0
      tofu -chdir="${dir}" init "$@" || rc=$?
    else
      echo "[*] The OpenTofu provider cache ${TF_PLUGIN_CACHE_DIR} is inconsistent: empty it and re-run." >&2
    fi
  fi
  return ${rc}
}

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

# Argus detection engine (charts/straiker-defend) — backs Straiker's "Defend"
# product, but always installed regardless of PRODUCTS_OPT: charts/straiker-
# ascend's own probe-worker/recon-worker call Argus's /api/v1/detect directly
# for several detection categories (amt_attack_* and others), so an Ascend-
# only install still needs it running. Runs after straiker-inference and
# straiker-system.
DEFEND_RELEASE="straiker-defend"

# Defend's detection engine: v1 (charts/straiker-defend, the default for now) or v3 (charts/straiker-argus-v3, Argus v3, needs
# --data-layer). v3 runs next to v1 until Ascend is moved to it; then v3 becomes the default and v1 is removed.
# Resolved by resolve_defend_engine() (flag > remembered > the data layer's v3 > v1); empty until then.
DEFEND_ENGINE="${DEFEND_ENGINE:-}"
DEFEND_CHART_NAME="straiker-defend"

# How the local model servers (GPU) are provided. Profile: production (default; one server per GPU, never shared or
# quantized: what customers get) or test (opt-in; may time-slice GPUs and quantize so a small cluster runs the whole fleet).
# Mode: vllm (default; the model fleet runs on GPU nodes here) or bedrock (no GPU fleet). Bedrock is also used by Argus v3's
# context reviewer in every mode, so it is checked whenever --defend-engine v3 is selected.
INFERENCE_PROFILE="${INFERENCE_PROFILE:-}"
INFERENCE_MODE="${INFERENCE_MODE:-}"
# TESTING ONLY (not remembered): deploy just these models of the selected products, e.g. when GPU quota covers part of the fleet.
INFERENCE_MODELS="${INFERENCE_MODELS:-}"
GPU_PLANNER="${REPO_ROOT}/scripts/gpu_planner.py"
GPU_MODELS_FILE="${REPO_ROOT}/scripts/gpu-models.json"
# EC2 service quota "Running On-Demand G and VT instances" (vCPUs); one server needs about 4.2 vCPUs, so Karpenter picks a .2xlarge node (8 vCPUs).
GPU_VCPU_QUOTA_CODE="L-DB2E81BA"
GPU_NODE_VCPUS=8
# GPU fleet shape (remembered): p4d (default; customer installs, the reference architecture) packs every model server onto
# p4d.24xlarge nodes, 8x A100 40 GB each, one server per GPU: the full fleet (10 servers) is 2 nodes and the pool may grow
# to GPU_MAX_NODES. per-model: one small node per server on the tier each model is validated for (g4dn/g5/g6/g6e), for
# Straiker's own test installs. An install whose models already run without a remembered choice keeps per-model.
GPU_FLEET="${GPU_FLEET:-}"
# Which EC2 type the "p4d" (packed) fleet uses — defaults to p4d.24xlarge (the reference architecture). Override with
# --gpu-instance-type for a stand-in that is faster to get capacity for (e.g. g6e.12xlarge, 4x L40S) while A100/p4d
# capacity is being arranged; same "one pinned type, pack servers onto its GPUs" shape either way. Must be a type
# gpu_instance_spec() below (and scripts/gpu_planner.py's INSTANCE_GPUS) knows the GPU count of.
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-}"
GPU_MAX_NODES="${GPU_MAX_NODES:-}"
# Optional EC2 Capacity Reservation(s) / Capacity Block(s) for the GPU nodes (comma-separated cr-... ids). Remembered.
GPU_CAPACITY_RESERVATION="${GPU_CAPACITY_RESERVATION:-}"
# Which Availability Zones the cluster uses, in order (comma-separated, e.g. us-west-2c,us-west-2a): 2 or 3 of them. The FIRST is
# the primary: --provision-strategy min runs every node there. Empty = the region's first 2 AZs (3 with --provision-strategy max).
# Fixed once the cluster exists. Not with --vpc-id (the AZs then come from the subnets you supply).
AVAILABILITY_ZONES_OPT="${AVAILABILITY_ZONES_OPT:-}"
# Skips the GPU capacity probe (a brief real launch of the fleet's GPU instances right after the cluster is built).
SKIP_CAPACITY_PROBE="${SKIP_CAPACITY_PROBE:-false}"
P4D_INSTANCE_TYPE="p4d.24xlarge"
P4D_GPUS_PER_NODE=8
P4D_NODE_VCPUS=96
# EC2 service quota "Running On-Demand P instances" (vCPUs): p4d/p4de/p5 count here, not in the G/VT quota.
P_VCPU_QUOTA_CODE="L-417A185B"
DEFEND_SERVICE_ACCOUNT="straiker-defend"

# Bedrock inference profiles Argus v3 may invoke (space-separated), as SaaS grants its argus pods: sol is the engine's context
# reviewer default (infra PR #198), terra sits alongside it. Each is an inference profile, so the grant covers the profile
# and the foundation model behind it (any region).
ARGUS_V3_BEDROCK_PROFILES="${ARGUS_V3_BEDROCK_PROFILES:-global.openai.gpt-5.6-sol global.openai.gpt-5.6-terra}"
ARGUS_V3_RELEASE="argus-v3"
ARGUS_V3_SECRET="argus/v3"

# Iris automated red-teaming engine (charts/straiker-ascend) — Straiker's
# "Ascend" product. Installed only when "ascend" is in PRODUCTS_OPT, after
# straiker-inference, straiker-system, and straiker-core.
ASCEND_RELEASE="straiker-ascend"
ASCEND_CHART_NAME="straiker-ascend"
ASCEND_SERVICE_ACCOUNT="straiker-ascend"

# Artifact broker Lambda Function URL — AWS counterpart to the former GCP Cloud
# Function. Returns KEY=VALUE lines (eval-consumable AWS STS creds) from /token,
# JSON from /bifrost-trial and /whoami. Fixed, same for every install.
ARTIFACT_BROKER_BASE_URL="https://2a7owzgkie5zw6dfl4qqg6tfhe0pqkvb.lambda-url.us-east-1.on.aws"
ARTIFACT_BROKER_BIFROST_TRIAL_URL="${ARTIFACT_BROKER_BASE_URL}/bifrost-trial"
ARTIFACT_BROKER_WHOAMI_URL="${ARTIFACT_BROKER_BASE_URL}/whoami"
# Default Bifrost base URL used when the broker's /bifrost-trial response does
# not include a base_url (customer secret not yet seeded with one).
DEFAULT_BIFROST_BASE_URL="https://bifrost.stage.straiker.ai/v1"

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

# Opt-in (--data-layer): provision the AWS-managed data tier (Aurora PostgreSQL,
# ElastiCache Serverless Redis, MSK Serverless, EFS model cache, KMS, Secrets
# Manager) via terraform/aws/data, in phase 'aws-data'. Off by default so
# existing installs (in-cluster Postgres/Valkey) are untouched.
DATA_LAYER="${DATA_LAYER:-false}"
# Platform services installed by phase platform-services (also drives platform-sa's IAM grants).
PLATFORM_SERVICES_EXPLICIT=false
[[ -n "${PLATFORM_SERVICES:-}" ]] && PLATFORM_SERVICES_EXPLICIT=true
PLATFORM_SERVICES="${PLATFORM_SERVICES:-foundation databridge portico api-gateway}"

# Kubernetes API server exposure, and the NAT gateway count that
# provision_strategy would otherwise dictate on its own. All three get the
# same first-run-only treatment as PROVISION_STRATEGY, for a reason specific
# to each:
#   - CLUSTER_PUBLIC_ACCESS: a customer who has deliberately taken their
#     control plane off the internet must never have it silently put back by
#     a later `tofu apply` (which runs -auto-approve, so nobody sees the
#     plan). phase_eks_cluster additionally refuses to re-enable public
#     access it finds disabled on the live cluster, covering the case where
#     the change was made by hand outside this installer.
#   - CLUSTER_API_ALLOWED_CIDRS: pairs with the above -- disabling public
#     access without this locks every operator out.
#   - SINGLE_NAT_GATEWAY: changing NAT topology replaces the gateway and
#     therefore its Elastic IP, which breaks any downstream allowlist pinned
#     to that egress address.
# Empty CLUSTER_PUBLIC_ACCESS_CIDRS defers to terraform's own 0.0.0.0/0
# default rather than encoding it twice.
CLUSTER_PUBLIC_ACCESS="${CLUSTER_PUBLIC_ACCESS:-true}"
CLUSTER_PUBLIC_ACCESS_CIDRS="${CLUSTER_PUBLIC_ACCESS_CIDRS:-}"
CLUSTER_API_ALLOWED_CIDRS="${CLUSTER_API_ALLOWED_CIDRS:-}"
SINGLE_NAT_GATEWAY="${SINGLE_NAT_GATEWAY:-}"

# How Ascend's recon-agent reaches an AI provider: own-keys (bring-your-own
# OpenAI/Anthropic/xAI key(s)), bedrock (AWS Bedrock via Pod Identity — no
# static keys), or trial-key (a Straiker-hosted temporary virtual key,
# fetched automatically from the artifact broker). Only asked when 'ascend'
# is selected. Unlike CLOUD_PROVIDER/PROVISION_STRATEGY, safe to change on a
# later run via --ai-provider-mode — Terraform will create/destroy the Bedrock
# IAM role accordingly on the next aws-artifacts run.
AI_PROVIDER_MODE="${AI_PROVIDER_MODE:-}"

# Cross-region inference profile prefix baked into Bedrock's Claude model ids
# (e.g. "global.anthropic.claude-sonnet-4-6" vs "us.anthropic.claude-sonnet-4-6")
# - "global" dynamically routes to whichever region has capacity, no pricing
# premium; "regional" pins to the customer's own region's profile instead, at
# the cost of that model needing a real endpoint in that specific profile
# family (not every model has one in every region - see
# iris/common/settings/settings.py's bedrock_inference_profile field, which
# defaults to "global"). This installer's own interactive prompt defaults to
# "regional" instead: onprem customers are more likely to need data
# residency than to need global's cost savings. AWS groups regions into
# profile families broader than a literal region name (us-east-1 and
# us-west-2 are both "us"); this maps BEDROCK_REGION to its containing
# family. Unrecognized regions fall back to "global" rather than guessing a
# family with no real coverage.
bedrock_profile_for_region() {
  case "$1" in
    us-*) echo "us" ;;
    eu-*) echo "eu" ;;
    ap-*) echo "apac" ;;
    *) echo "global" ;;
  esac
}

# Provider credential values, captured interactively right after
# AI_PROVIDER_MODE is chosen. Held in memory only, never persisted to
# ~/.straiker/install.json; phase_ai_provider_secrets writes whichever of
# these are non-empty once the cluster/Secret exist.
AI_OPENAI_KEY=""
AI_ANTHROPIC_KEY=""
AI_XAI_KEY=""
AI_TRIAL_VIRTUAL_KEY=""
# Fetched alongside AI_TRIAL_VIRTUAL_KEY from the same artifact-broker
# response.
AI_TRIAL_BIFROST_BASE_URL=""

# How straiker-edge exposes app/defend/ascend externally: internal (Caddy
# reverse proxy, self-signed certs — current behavior, default), none (no
# edge/ingress installed — bring your own), tailscale (same Caddy, but a
# real cert-manager/Let's Encrypt certificate for the customer's own domain,
# Service exposed onto their own Tailscale tailnet at L3 via the Tailscale
# Kubernetes operator — see TAILSCALE_OAUTH_CLIENT_ID/CUSTOM_ORIGIN_DOMAIN/
# TAILSCALE_CLUSTER_ISSUER_EMAIL below), or alb (one Ingress covering all
# routes via host-based rules, backed by a single internal AWS Application
# Load Balancer through the AWS Load Balancer Controller — for
# no-public-internet customers, e.g. accessed via WorkSpaces Secure
# Browser. Safe to change on a later run, same as AI_PROVIDER_MODE — just
# re-run with --edge-type and re-run the affected phases.
EDGE_TYPE="${EDGE_TYPE:-}"

# Tailscale OAuth client credentials for 'tailscale' edge type — always
# bring-your-own: created by hand in the Tailscale admin console (see
# examples/edge/tailscale.md), scoped to tag:k8s-operator. Held in memory
# only, never persisted to ~/.straiker/install.json (same treatment as the
# AI_* keys above) — this installer never creates or mints Tailscale
# credentials itself.
TAILSCALE_OAUTH_CLIENT_ID=""
TAILSCALE_OAUTH_CLIENT_SECRET=""

# Contact email for the Let's Encrypt ACME account charts/straiker-edge's
# ClusterIssuer registers (see templates/cert-manager.yaml). Not a secret —
# persisted as plain metadata. Only asked/used when EDGE_TYPE=tailscale.
TAILSCALE_CLUSTER_ISSUER_EMAIL="${TAILSCALE_CLUSTER_ISSUER_EMAIL:-}"

# Tailscale's own Helm chart repo — distinct from HELM_REPO_NAME/HELM_REPO_URL
# (Straiker's own chart repo, added fresh in every phase_* function below).
TAILSCALE_HELM_REPO_NAME="tailscale"
TAILSCALE_HELM_REPO_URL="https://pkgs.tailscale.com/helmcharts"
TAILSCALE_OPERATOR_RELEASE="tailscale-operator"
TAILSCALE_OPERATOR_NAMESPACE="tailscale"

# Used when EDGE_TYPE=none, alb, xalb, or tailscale. Not a secret —
# persisted as plain metadata. Keeps straiker-core's/straiker-ascend's
# OIDC-origin/CORS overrides in sync with wherever app/defend/ascend
# actually routes. With EDGE_TYPE=none, blank (default) means "unchanged" —
# the customer sets frontend.origin/etc. overrides manually themselves.
# With alb/xalb/tailscale it's required (also becomes charts/straiker-edge's
# alb.domain/xalb.domain/tailscale.domain) — those modes have no meaning
# without a domain.
CUSTOM_ORIGIN_DOMAIN="${CUSTOM_ORIGIN_DOMAIN:-}"

# Required for EDGE_TYPE=alb/xalb unless the respective Route53 automation
# is enabled (--alb-route53/--xalb-route53) — charts/straiker-edge's
# alb.certificateArn/xalb.certificateArn (see phase_straiker_edge). Not a
# secret — persisted as plain metadata. ACM certificate ARN for the ALB's
# HTTPS listener; the AWS Load Balancer Controller creates no HTTPS
# listener without one. No self-signed fallback for either edge type —
# request a real one via DNS validation, which works even with zero public
# reachability (only a Route53 CNAME is needed to prove domain control).
# The default for both edge types: bring your own ARN, works regardless of
# which AWS account (or DNS provider) actually hosts the domain's zone —
# --alb-route53/--xalb-route53 (below) are opt-in conveniences only for the
# common case where that zone happens to live in this same AWS account.
ALB_CERTIFICATE_ARN="${ALB_CERTIFICATE_ARN:-}"
# Only used when EDGE_TYPE=alb. Provisions a tiny EC2 bastion
# (terraform/aws/edge) reachable via 'aws ssm start-session' port
# forwarding, no public IP/SSH key, so whoever is installing can verify the
# ALB is reachable before DNS/handoff is fully sorted out. Not a
# customer-facing access path. (xalb has no equivalent — it's genuinely
# public, so there's no reachability gap to bridge.)
ALB_PROVISION_BASTION="${ALB_PROVISION_BASTION:-}"
# Only used when EDGE_TYPE=alb. Opt-in, off by default — pass --alb-route53
# to enable. When enabled: auto-issues+validates a real ACM certificate via
# Route53 DNS validation (no --alb-certificate-arn needed), same mechanism
# as XALB_ROUTE53_AUTOMATION below (terraform/aws/edge's route53.tf is
# already generic, gated only on enable_route53_automation — this just
# wires alb into it too). Only works when the domain's Route53 zone is in
# this same AWS account — the default (disabled) is the one that works
# regardless of DNS/account topology, since it just requires an ARN you
# already have. Unlike xalb, doesn't also install ExternalDNS — alb is
# internal-only, so there's no public-facing DNS record for it to manage;
# just point your own internal DNS at the ALB (see show_access_info).
ALB_ROUTE53_AUTOMATION="${ALB_ROUTE53_AUTOMATION:-}"
# Only used when EDGE_TYPE=xalb. Opt-in, off by default — pass --xalb-route53
# to enable. When enabled: auto-issues+validates a real ACM certificate via
# Route53 DNS validation (no --alb-certificate-arn needed) and installs
# ExternalDNS to keep the app hostnames pointed at the ALB automatically.
# Only works when the domain's Route53 zone is in this same AWS account —
# the default (disabled) is the one that works regardless of DNS/account
# topology, since it just requires an ARN you already have.
XALB_ROUTE53_AUTOMATION="${XALB_ROUTE53_AUTOMATION:-}"
# Optional, only used when EDGE_TYPE=alb — charts/straiker-edge's
# alb.subnets. Comma-separated subnet IDs; blank means rely on the AWS Load
# Balancer Controller's subnet auto-discovery
# (kubernetes.io/role/internal-elb=1 tag on private subnets).
ALB_SUBNETS="${ALB_SUBNETS:-}"
# AWS WAF on the edge ALB (edge types alb/xalb; terraform/aws/edge's waf.tf): always created for those edge types.
# Requests per 5 minutes allowed from one source IP (rate-based rule); 0 turns the rate rule off (the managed rules
# stay). Remembered in install state. Default: terraform/aws/edge's own (10000).
WAF_RATE_LIMIT="${WAF_RATE_LIMIT:-}"
# CIDR allowed to reach the ALB (e.g. the customer's corporate range, or a
# narrower one like the subnets a WorkSpaces Secure Browser portal uses) —
# required whenever EDGE_TYPE=alb, since the AWS Load Balancer Controller
# has no restriction by default (0.0.0.0/0), which "internal" scheme alone
# does not prevent.
INTERNAL_LB_SOURCE_RANGES="${INTERNAL_LB_SOURCE_RANGES:-}"

# ServiceAccount name this installer creates for bifrost — must match the
# bifrost chart's own serviceAccountName value.
BIFROST_SERVICE_ACCOUNT="straiker-bifrost"

TF_PREFIX="s6r-onprem"
CLUSTER_NAME=""
INSTALL_EKS=false
INSTALL_EKS_EXPLICIT=false
PROVISION_STRATEGY_EXPLICIT=false
# Set by --private-api-endpoint/--api-public-cidrs/--api-allowed-cidrs/
# --single-nat-gateway. Distinguishes "operator asked for the default" from
# "operator said nothing", so the first-run prompt is skipped only when an
# explicit choice was made (same contract as PROVISION_STRATEGY_EXPLICIT).
CLUSTER_ENDPOINT_EXPLICIT=false
SINGLE_NAT_GATEWAY_EXPLICIT=false
# Bring-your-own-VPC (terraform/aws/eks's vpc_id variable) — for customers
# whose IAM/SCP denies ec2:CreateVpc. All three empty (the default) means
# "let this installer create its own VPC," unchanged from today. Foundational
# like CLOUD_PROVIDER/PROVISION_STRATEGY above: first-run-only, see the
# vpc_id_set metadata handling below.
VPC_ID=""
PRIVATE_SUBNET_IDS=""
PUBLIC_SUBNET_IDS=""
INSTALL_TOFU=false
AUTO_YES=false
PLAN_ONLY=false
STATUS_ONLY=false
FORCE_RERUN=false
# One-off action, not part of the normal phase pipeline — see
# update_alb_certificate()'s own comment.
UPDATE_ALB_CERTIFICATE=false
ALB_CERT_FILE="${ALB_CERT_FILE:-}"
ALB_KEY_FILE="${ALB_KEY_FILE:-}"
ALB_CHAIN_FILE="${ALB_CHAIN_FILE:-}"

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
declare -a ALL_PHASES=("eks-tfbe" "eks-cluster" "karpenter" "k8s-preflight" "aws-artifacts" "gateway-cert" "aws-data" "external-secrets" "artifacts-sync" "straiker-system" "shared-secrets" "clickhouse" "data-bootstrap" "ch-sync" "platform-services" "ingest" "verify-data-layer" "ai-provider-secrets" "straiker-core" "straiker-inference" "straiker-defend" "straiker-argus-v3" "straiker-ascend" "tailscale-operator" "edge-infra" "cert-manager" "alb-controller" "external-dns" "straiker-edge" "observability")
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
  --update-alb-certificate         One-off action, not part of the normal install: re-imports
                                   a certificate into the ACM ARN edge type 'alb'/'xalb' is
                                   already using (same ARN — no Helm upgrade or re-install
                                   needed, the ALB picks it up automatically) and exits.
                                   Requires --alb-cert-file/--alb-key-file (and optionally
                                   --alb-chain-file). Useful for rotating an imported
                                   certificate that doesn't auto-renew (ACM-issued
                                   DNS-validated certificates, e.g. xalb's default, renew
                                   themselves and don't need this).
  --alb-cert-file <path>          Required with --update-alb-certificate. PEM certificate file.
  --alb-key-file <path>           Required with --update-alb-certificate. PEM private key file.
  --alb-chain-file <path>         Optional with --update-alb-certificate. PEM certificate chain file.
  --phase <name>[,<name>...]       Run only the given phase(s), in the listed order.
  --from-phase <name>             Run from phase through the end.
  --rerun-phase                   Re-run selected phases even if already marked done.
  --data-layer                    Also provision the AWS-managed data tier (Aurora PostgreSQL,
                                   ElastiCache Serverless Redis, MSK Serverless, EFS, KMS, Secrets
                                   Manager) in phase 'aws-data'. Sized by --provision-strategy.
                                   Needs an existing EKS cluster (ours or --cluster-name).
  --install-eks                   Also provision an EKS cluster via Terraform (the AWS
                                   bootstrap phase runs regardless of this flag).
  --install-tofu                  Download and install OpenTofu ${TOFU_VERSION} to
                                   ~/.local/bin/tofu before running any phase that needs
                                   it. No sudo required. Idempotent — skipped if the
                                   correct version is already installed.
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
  --private-api-endpoint          Disable public internet access to the Kubernetes API server
                                   (default: public access enabled, as today). AWS resolves the
                                   cluster endpoint through public DNS to its private VPC address,
                                   so kubectl keeps working from any network that ROUTES to the
                                   VPC (Transit Gateway / Direct Connect / VPN) — no bastion and
                                   no CloudShell VPC environment needed. Requires
                                   --api-allowed-cidrs, otherwise nothing can reach the API at
                                   all. First-run-only, like --provision-strategy: once set it is
                                   permanent for this install and later invocations cannot flip
                                   it back. This installer also refuses to re-enable public access
                                   on a live cluster where it was disabled by hand.
  --api-public-cidrs <cidrs>      Comma-separated CIDRs allowed to reach the PUBLIC API endpoint
                                   (default: 0.0.0.0/0). Narrowing this to your corporate egress
                                   range is the lighter-touch alternative to
                                   --private-api-endpoint — it needs no VPC routing. Ignored when
                                   --private-api-endpoint is set. First-run-only.
  --api-allowed-cidrs <cidrs>     Comma-separated CIDRs allowed to reach the PRIVATE API endpoint
                                   on 443, added to the EKS-managed cluster security group. Set
                                   this to the on-prem/corporate ranges that reach the VPC over
                                   Transit Gateway/Direct Connect/VPN. Required in practice
                                   whenever --private-api-endpoint is used. First-run-only.
  --single-nat-gateway            Create ONE NAT gateway even under --provision-strategy ha/max
                                   (which otherwise create one per AZ, i.e. 3 Elastic IPs). Use
                                   when a downstream firewall or vendor allowlist needs a single
                                   stable egress IP to pin. Trade-off: that NAT becomes an
                                   AZ-level single point of failure for outbound traffic, and
                                   egress from the other AZs crosses AZ boundaries (inter-AZ data
                                   transfer charges). No effect with --vpc-id (this installer
                                   creates no NAT gateway in bring-your-own-VPC mode).
                                   First-run-only: changing NAT topology later replaces the
                                   gateway and its Elastic IP, breaking any pinned allowlist.
  --vpc-id <vpc-id>               Attach EKS to an existing VPC instead of creating one (e.g.
                                   when an AWS Organizations SCP denies ec2:CreateVpc). Requires
                                   --private-subnet-ids and --public-subnet-ids together. Needs
                                   ec2:DescribeVpcs/DescribeSubnets/CreateTags/DeleteTags on the
                                   supplied VPC (not ec2:CreateVpc) — this installer tags your
                                   subnets kubernetes.io/role/*-elb and karpenter.sh/discovery,
                                   which Karpenter/the AWS Load Balancer Controller need, but
                                   does NOT create a NAT gateway: your private subnets must
                                   already have outbound internet routing. Only used with
                                   --install-eks; irrelevant for bring-your-own-cluster installs.
                                   Same first-run-only treatment as --cloud-provider.
  --private-subnet-ids <ids>      Comma-separated private subnet IDs (>=2, spanning >=2 AZs).
                                   Required with --vpc-id. Order matters under
                                   --provision-strategy min: only the first subnet's AZ is used
                                   for the system node group and Karpenter-launched nodes.
  --public-subnet-ids <ids>       Comma-separated public subnet IDs, tagged for the AWS Load
                                   Balancer Controller. Required with --vpc-id.
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
  --tf-prefix <prefix>            Prefix for the Terraform state bucket and for the account-wide IAM roles the install creates
                                   (alb-controller, external-dns, hauler, models-reader, ...), default: s6r-onprem. A second
                                   install in the SAME AWS account needs its own prefix, or those role names collide.
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
                                   OpenAI/Anthropic/xAI key(s)), bedrock (AWS Bedrock via EKS Pod
                                   Identity — installer creates the IAM role; AWS still requires
                                   model entitlement for the selected Bedrock models), or trial-key
                                   (a Straiker-hosted temporary virtual key, up to 30 days,
                                   PoC/trial use only, fetched automatically — no separate key to
                                   hold). Unlike --cloud-provider/--provision-strategy, safe to
                                   change on a later run — just pass this flag again and re-run
                                   --phase aws-artifacts,ai-provider-secrets,straiker-core
                                   --rerun-phase. If omitted, you'll be prompted interactively
                                   the first time 'ascend' is selected.
  --edge-type <internal|none|tailscale|alb|xalb>
                                   How straiker-edge exposes app/defend/ascend externally
                                   (default on EKS: xalb = an internet-facing AWS Application
                                   Load Balancer with an ACM certificate and AWS WAF, which
                                   also carries the api-gateway (--gateway-domain, default
                                   api.<--custom-domain>); default elsewhere: none). internal = Caddy reverse proxy with
                                   self-signed certs. none = install nothing; bring your own
                                   ingress/LoadBalancer (default on GKE). tailscale = same
                                   Caddy as internal, but with a real cert-manager/Let's
                                   Encrypt certificate for your own domain (see
                                   --custom-domain/--tailscale-cluster-issuer-email) and its
                                   Service exposed onto your own Tailscale tailnet at L3 via
                                   the Tailscale Kubernetes operator — bring your own OAuth
                                   client, created by hand in the Tailscale admin console
                                   first (see examples/edge/tailscale.md). alb = one Ingress
                                   covering all routes via host-based rules, backed by a
                                   single internal AWS Application Load Balancer — for
                                   customers with no public internet access (e.g. accessed via
                                   WorkSpaces Secure Browser). The AWS Load Balancer
                                   Controller itself is installed automatically (phase
                                   'alb-controller', IAM via terraform/aws/edge) unless an
                                   'alb' IngressClass already exists. See
                                   --custom-domain/--alb-certificate-arn/
                                   --internal-lb-source-ranges/--alb-subnets.
                                   Unlike --cloud-provider/--provision-strategy, safe to
                                   change on a later run — just pass this flag again and
                                   re-run --phase tailscale-operator,cert-manager,straiker-edge
                                   --rerun-phase. If omitted, you'll be prompted interactively
                                   the first time (before every other question).
  --tailscale-oauth-client-id <id>
  --tailscale-oauth-client-secret <secret>
                                   Required with --edge-type tailscale. The OAuth client you
                                   created by hand in the Tailscale admin console (Settings →
                                   OAuth clients), scoped to tag:k8s-operator — see
                                   examples/edge/tailscale.md. This installer never creates or
                                   mints Tailscale credentials itself. If omitted, you'll be
                                   prompted interactively.
  --tailscale-cluster-issuer-email <email>
                                   Required with --edge-type tailscale. Contact email for the
                                   Let's Encrypt ACME account charts/straiker-edge's
                                   ClusterIssuer registers. Not a secret.
  --admin-email <address>          With --data-layer: the first admin. Login is Amazon Cognito (user pool from
                                   phase 'aws-data'); the installer creates this user with a password kept in
                                   Secrets Manager. Remembered in install state; required by phase 'straiker-core'.
  --reset-admin-password           Set the first admin's Cognito password again from Secrets Manager (recovery).
  --rotate-admin-password          Generate a new password for the first admin (kept in Secrets Manager) and set it.
  --saas-frontend                  With --data-layer: also create the AWS backends of the SaaS frontend (DynamoDB
                                   environment + guardrail tables, Kinesis audit stream) and a Pod Identity role for
                                   the frontend. Remembered in install state; needs a SaaS-style frontend image.
  --defend-engine <v1|v3>          Defend's detection engine. v3 (default with --data-layer): Argus v3 (phase straiker-argus-v3),
                                   which the console's Controls page and the Detect API need; run next to v1
                                   (charts/straiker-defend) until Ascend moves to it. v1 (default without --data-layer): v1 only.
                                   Remembered in install state; a later run without the flag keeps it.
  --inference-profile <production|test>
                                   production (default): one model server per GPU, never shared or quantized, on the GPU
                                   tier each model is validated for. test: opt-in for small clusters; may time-slice GPUs
                                   that already exist and quantize thanos. NEVER use test for a customer. Remembered.
  --gpu-fleet <p4d|per-model>      p4d (default; customer installs): every model server packed onto nodes of one
                                   EC2 type (p4d.24xlarge, 8x A100 40 GB, unless --gpu-instance-type overrides it),
                                   one server per GPU; the full fleet is however many nodes that takes (2 for
                                   p4d.24xlarge) and the pool grows to --gpu-max-nodes. Needs the matching EC2 quota
                                   (P-instance for p4d/p4de/p5; G-and-VT for g5/g6/g6e). per-model: one g4dn/g5/g6/g6e
                                   node per server, each model's validated tier (Straiker test installs). An existing
                                   install keeps what it runs. Remembered.
  --gpu-instance-type <type[,type]> p4d fleet only: the EC2 type to pack the fleet onto instead of p4d.24xlarge. Several types with the
                                   same GPU count may be listed, largest first (g6e.4xlarge,g6e.2xlarge,g6e.xlarge): capacity is per
                                   type, so Karpenter uses whichever has it. (e.g.
                                   g6e.12xlarge, 4x L40S — a stand-in while A100 capacity is being arranged; same
                                   packed shape, checked against the quota that type actually falls under). Remembered.
  --gpu-max-nodes <n>              p4d fleet: most GPU nodes the pool may grow to (default 4). Remembered.
  --gpu-capacity-reservation <ids> EC2 Capacity Reservation / Capacity Block id(s) (cr-..., comma-separated) the GPU
                                   nodes launch into first. Remembered.
  --availability-zones <a,b[,c]>   The Availability Zones the cluster uses, in order (e.g. us-west-2c,us-west-2a): 2 or 3.
                                   The first is the primary (--provision-strategy min runs every node there). Default: the
                                   region's first 2 (3 with --provision-strategy max); with --gpu-capacity-reservation, the
                                   reservation's AZ is put first. Fixed once the cluster exists. Not with --vpc-id.
  --inference-mode <vllm|bedrock>  vllm (default): run the model fleet on GPU nodes in this cluster. bedrock: no GPU
                                   fleet (Argus v3's vision/wanda/Kev controls and Ascend's thanos are then unavailable;
                                   use --ai-provider-mode bedrock for Ascend). Remembered.
  --inference-models <a,b,c>       TESTING ONLY. Deploy only these models (of vision, wanda, kev-agentic, kev-non-agentic, thanos
                                   that the selected products use), for a run where GPU quota covers part of the fleet. Not
                                   remembered: pass it only with --phase straiker-inference, never for a customer install.
  --gateway-exposure <mode>        Who can reach the platform api-gateway (the API behind the console and SDK calls):
                                   public (default): internet-facing load balancer, TLS required (--gateway-cert-arn),
                                   best limited with --gateway-allowed-cidrs. internal: internal load balancer, VPC /
                                   private network only (choose it explicitly). none: in-cluster only (ClusterIP).
                                   Remembered. Without --gateway-cert-arn the default stops and asks for a certificate
                                   or --gateway-exposure internal: API keys never cross the internet in clear text.
  --gateway-domain <fqdn>          The gateway's hostname, e.g. api.customer.com (the default internet-facing gateway needs this or
                                   --gateway-cert-arn). The installer requests the ACM certificate (DNS validation) and, when a public
                                   Route53 zone for the domain is in this account, adds the validation record, waits for the
                                   certificate and points the name at the load balancer: no manual step. DNS elsewhere: it prints the
                                   validation record to add (early, while the rest installs) and the final record for the name.
  --gateway-zone-id <id>           Route53 hosted zone to use for --gateway-domain (default: found by the domain's name).
  --gateway-cert-arn <arn>         Your own ACM certificate for the gateway's TLS listener (same region); used as is, no issuing.
  --gateway-allowed-cidrs <list>   Comma-separated source CIDRs allowed to reach a public gateway (default: any).
  --sso-type <type>                With --data-layer: the customer's identity provider for "Sign in with SSO",
                                   federated into the Cognito pool (one per install; all need --sso-domains):
                                     google | facebook | amazon | apple   built-in providers
                                     saml | oidc                          any other provider (needs --sso-name)
                                   Values per type (secrets from the environment, or a hidden prompt on a terminal):
                                     google/facebook/amazon  --sso-client-id <id>, env SSO_CLIENT_SECRET
                                     apple   --sso-client-id <Services ID> --sso-apple-team-id <id>
                                             --sso-apple-key-id <id> --sso-apple-private-key-file <p8 file>
                                     saml    --sso-saml-metadata-url <https url> or --sso-saml-metadata-file <xml>
                                     oidc    --sso-oidc-issuer <https url> --sso-client-id <id>, env SSO_CLIENT_SECRET
                                   Remembered in install state; re-run phases aws-data and straiker-core to apply.
                                   A hand-over sheet for the customer's IT is written to ~/.straiker/.
  --sso-name <name>                saml/oidc only: the provider's name in Cognito (3-32 letters, digits, hyphens).
  --sso-domains <a.com,b.com>      Email domains allowed to sign in through SSO (new users are created as viewers).
  --sso-email-claim <claim>        The provider's claim/attribute carrying the user's email, when not the standard one
                                   (e.g. Entra OIDC without an email claim: preferred_username).
  --allow-sso-change               Allow replacing a different SSO provider already set up (users signed in through
                                   the old one are orphaned).
  --skip-capacity-probe            Skip the pre-build GPU zone probe (a brief real launch of the fleet's GPU instances in a temporary
                                   VPC, one zone at a time, to start the cluster in a zone that has capacity). Needs
                                   ec2:RunInstances/TerminateInstances. It never blocks: with no capacity anywhere the install
                                   continues and waits for GPU nodes (up to 6 hours, any type listed in --gpu-instance-type).
  --skip-sso-preflight             Skip the reachability / certificate checks of the SAML metadata or OIDC issuer
                                   (use when this machine cannot reach a provider that AWS can).
  --ses-domain <domain>            With --data-layer: sending domain in Amazon SES. Cognito invitations / password
                                   resets come from no-reply@<domain>, connect from notifications@<domain>. DNS
                                   records are created in a Route53 zone of this account (found automatically,
                                   or created for the domain: delegate its NS records from the parent zone).
                                   New SES accounts are in the sandbox until AWS grants production access.
  --ses-route53-zone-id <id>       Use this hosted zone for the SES DNS records instead of detecting one.
  --ses-identity-arn <arn>         With --data-layer: use the customer's own, already verified SES identity instead of
                                   creating one (excludes --ses-domain; needs --ses-from). Nothing is created for it.
                                   An identity in another account needs a sending authorization policy that allows
                                   this account's Cognito and connect to use it.
  --ses-from <address>             The From address on that identity (Cognito mail; connect uses it too).
  --ses-configuration-set <name>   Optional SES configuration set (this account and region) for Cognito's mail.
  --custom-domain <domain>         Used when --edge-type none, alb, or tailscale is selected.
                                   Sets straiker-core's/straiker-ascend's
                                   OIDC-redirect-URI/CORS overrides to
                                   straiker.<domain>/straiker-defend.<domain>/straiker-ascend.<domain> — needed
                                   whenever you already know the domain your own (or the
                                   installed alb/Caddy) ingress/LoadBalancer will route
                                   through, or Dex's login will loop. With --edge-type none,
                                   leave unset (and answer blank at the prompt) to set these
                                   overrides yourself later via --values instead. With
                                   --edge-type alb/tailscale it's required — those modes have
                                   no meaning without a domain (for tailscale, it's also the
                                   domain the Let's Encrypt certificate covers).
  --alb-certificate-arn <arn>      Required with --edge-type alb unless --alb-route53 is also
                                   passed, and with --edge-type xalb unless --xalb-route53 is
                                   also passed. No self-signed fallback for either edge type —
                                   ACM certificate ARN for the Ingress's HTTPS listener, without
                                   which the AWS Load Balancer Controller creates no HTTPS
                                   listener at all. Request it via DNS validation; that works
                                   even with zero public reachability, only a Route53 CNAME is
                                   needed to prove domain control, and works regardless of
                                   which AWS account (or DNS provider) hosts the domain's zone.
  --alb-provision-bastion         Only used with --edge-type alb. Provisions a tiny EC2
                                   bastion (no public IP, no SSH key — reachable via 'aws ssm
                                   start-session' port-forwarding) so you can verify the ALB is
                                   reachable before DNS/handoff is fully sorted out.
  --alb-route53                   Only used with --edge-type alb. Opt-in convenience for the
                                   common case where the domain's Route53 zone is in this same
                                   AWS account: auto-issues+DNS-validates a real ACM
                                   certificate (--alb-certificate-arn no longer needed). Unlike
                                   --xalb-route53 below, doesn't install ExternalDNS — alb is
                                   internal-only, so there's no public DNS record to manage;
                                   point your own internal DNS at the ALB (see the access info
                                   printed at the end of the install). Leave unset if the zone
                                   lives elsewhere — bring your own --alb-certificate-arn
                                   instead.
  --xalb-route53                  Only used with --edge-type xalb. Opt-in convenience for the
                                   common case where the domain's Route53 zone is in this same
                                   AWS account: auto-issues+DNS-validates a real ACM
                                   certificate (--alb-certificate-arn no longer needed) and
                                   installs ExternalDNS to keep the app hostnames pointed at
                                   the ALB automatically. Leave unset if the zone lives
                                   elsewhere (a different AWS account, a different DNS
                                   provider) — bring your own --alb-certificate-arn and point
                                   DNS at the ALB yourself instead.
  --waf-rate-limit <n>             Edge types alb/xalb: requests per 5 minutes allowed from one
                                   source IP before AWS WAF blocks it (default 10000; 0 = no
                                   rate rule). WAF itself (AWS managed rules) is always on for
                                   these edge types. Remembered.
  --internal-lb-source-ranges <cidr>
                                   Optional with --edge-type alb. CIDR allowed to reach the
                                   ALB — the AWS Load Balancer Controller has no restriction
                                   by default otherwise (0.0.0.0/0), which "internal" scheme
                                   alone does not prevent. If omitted, phase 'straiker-edge'
                                   defaults it to this cluster's own VPC CIDR (looked up live,
                                   not 0.0.0.0/0) — meaningfully narrow, and naturally covers
                                   WorkSpaces Secure Browser's cross-account ENIs. Pass this
                                   explicitly for something narrower, e.g. a VPN's client CIDR
                                   pool.
  --alb-subnets <ids>              Optional with --edge-type alb. Comma-separated subnet IDs
                                   for the ALB. Leave unset to rely on the AWS Load Balancer
                                   Controller's subnet auto-discovery
                                   (kubernetes.io/role/internal-elb=1 tag on private subnets).
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
    # Auto-install tofu when --install-tofu was passed, rather than hard-exiting.
    if [[ "${cmd}" == "tofu" && "${INSTALL_TOFU}" == true ]]; then
      install_tofu
      return
    fi
    echo "ERROR: required command '${cmd}' is not installed or not on PATH." >&2
    exit 1
  fi
}

# Installs OpenTofu ${TOFU_VERSION} to ${TOFU_BIN} (no sudo required).
# Matches the logic in 1-bootstrap.sh: arch-aware, idempotent, linux only.
install_tofu() {
  local current_version
  current_version="$("${TOFU_BIN}" version -json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])' \
    2>/dev/null || echo "none")"
  if [[ "${current_version}" == "${TOFU_VERSION}" ]]; then
    log "OpenTofu ${TOFU_VERSION} already installed at '${TOFU_BIN}'."
    export PATH="${TOFU_INSTALL_DIR}:${PATH}"
    return
  fi

  require_command curl
  require_command unzip
  require_command python3

  local arch="amd64"
  [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"

  log "Installing OpenTofu ${TOFU_VERSION} (${arch}) to '${TOFU_BIN}'..."
  mkdir -p "${TOFU_INSTALL_DIR}"
  curl -fsSL \
    "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.zip" \
    -o /tmp/tofu.zip
  unzip -oq /tmp/tofu.zip -d /tmp/tofu-extract
  mv /tmp/tofu-extract/tofu "${TOFU_BIN}"
  chmod +x "${TOFU_BIN}"
  rm -rf /tmp/tofu.zip /tmp/tofu-extract

  export PATH="${TOFU_INSTALL_DIR}:${PATH}"
  log "OpenTofu installed: $(tofu version -json \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])')"
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

# The data tier builds AWS resource names from the cluster name: S3 buckets (<cluster>-<account>-grid-artifacts), the Cognito
# domain, the OpenSearch domain (<cluster>-oss, at most 28 characters), Aurora and ElastiCache identifiers. Those only accept
# lowercase letters, digits and hyphens, and OpenSearch's limit caps the name at 24. Fail here, with the reason, not in the
# aws-data phase after the cluster is already built.
validate_cluster_name() {
  [[ "${DATA_LAYER}" == "true" && -n "${CLUSTER_NAME}" ]] || return 0
  if [[ ! "${CLUSTER_NAME}" =~ ^[a-z]([a-z0-9-]{0,22}[a-z0-9])?$ ]]; then
    echo "ERROR: --cluster-name '${CLUSTER_NAME}' cannot be used with --data-layer: the data tier names S3 buckets, the Cognito domain, OpenSearch, Aurora and ElastiCache after it, which allow only lowercase letters, digits and hyphens (start with a letter, no trailing hyphen, at most 24 characters). Example: '$(printf '%s' "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n-' '-' | cut -c1-24)'." >&2
    exit 1
  fi
}

# --defend-engine: flag > remembered > v3 with --data-layer (Argus v3 is what the console's Controls page and the Detect API
# need; without it the registry cannot read the control catalog) > v3 if its phase already ran > v1. Remembered, so a later
# phase run without the flag does not silently fall back to v1.
resolve_defend_engine() {
  local v="${DEFEND_ENGINE}"
  [[ -n "${v}" ]] || v="$(get_metadata "defend_engine")"
  if [[ -z "${v}" ]]; then
    if [[ "$(get_phase_status "straiker-argus-v3")" == "done" || "${DATA_LAYER}" == "true" ]]; then v="v3"; else v="v1"; fi
  fi
  case "${v}" in v1 | v3) ;; *)
    echo "ERROR: --defend-engine must be v1 or v3 (got '${v}')." >&2
    exit 1
    ;;
  esac
  if [[ "${v}" == "v3" && "${DATA_LAYER}" != "true" ]]; then
    echo "ERROR: --defend-engine v3 needs --data-layer (Argus v3 uses MSK, ElastiCache and Secrets Manager from the data tier)." >&2
    exit 1
  fi
  DEFEND_ENGINE="${v}"
  set_metadata "defend_engine" "${v}"
}

# Refuse to run --cluster-name X against a state file that belongs to cluster Y: it would silently overwrite Y's remembered
# answers (cluster, domain, region, customer key) and reuse its certificates and "done" phases for X.
check_state_matches_cluster() {
  local persisted
  persisted="$(get_metadata "cluster_name" 2>/dev/null || true)"
  if [[ -n "${persisted}" && -n "${CLUSTER_NAME}" && "${persisted}" != "${CLUSTER_NAME}" ]]; then
    echo "ERROR: ${STATE_FILE} belongs to cluster '${persisted}', not '${CLUSTER_NAME}'. Each cluster needs its own state file:" >&2
    echo "  STRAIKER_STATE_FILE=~/.straiker/install-${CLUSTER_NAME}.json scripts/install-straiker.sh ... (same prefix on every command for that cluster)" >&2
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
  5b) aws-data            - (optional, requires --data-layer) provision Aurora PostgreSQL, ElastiCache
                             Serverless Redis, MSK Serverless, EFS, KMS and Secrets Manager via
                             terraform/aws/data, in the cluster's private subnets. Endpoints are
                             saved to install state for the later chart phases.
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
                             for argus calling straiker-inference. All three charts read
                             this same Secret name; this phase is what creates it.
  8a) clickhouse          - (optional, requires --data-layer) install chart 'straiker-clickhouse': single-node
                             ClickHouse pod (PVC), users and Secret 'clickhouse-credentials', database grid.
                             Runs before data-bootstrap, which projects its address/credentials into
                             'platform-secret'. Ingestion into it is not included.
  8b) data-bootstrap      - (optional, requires --data-layer) create the Aurora admin Secret and install
                             chart 'straiker-data': per-service databases/roles + DSN Secret
                             'straiker-db-dsn', and the MSK topics (Jobs, SASL/IAM via Pod Identity).
  8b2) ch-sync            - (optional, requires --data-layer) install chart 'straiker-ch-sync': creates the grid.*
                             CDC replica tables in ClickHouse and syncs them every minute from the registry
                             Postgres DB (read-only role grid_cdc). Replaces the ClickPipes Postgres pipe.
  8c) platform-services   - (optional, requires --data-layer) install the vendored platform charts
                             (charts/platform-<svc>, overlay values-onprem.yaml) from the ECR mirror:
                             PLATFORM_SERVICES, default "foundation databridge portico api-gateway", plus registry and
                             grid with --data-layer (they need ClickHouse). connect needs SES, so it is opt-in.
  8d) ingest              - (optional, requires --data-layer) install chart 'straiker-ingest': Redpanda Connect
                             streams s6r.events / s6r.findings / platform.audit -> ClickHouse grid.* landing
                             tables (MSK SASL/IAM; rejects go to <topic>.dlq). Replaces the ClickPipes Kafka pipes.
                             Needs grid's migration to have created the tables (phase platform-services with grid).
  8e) verify-data-layer   - (optional, requires --data-layer) post-install checks, run before the app
                             charts: EFS CSI driver + models PVC Bound, ElastiCache PING over TLS,
                             Aurora sslmode=require (iris role), and no failed Jobs. Any FAIL blocks the run.
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
                             need (charts/straiker-inference — Defend's Argus v3 needs vision, wanda,
                             kev-agentic and kev-non-agentic, Ascend's iris needs thanos).
                             Each model is its own release (named 'inference-<model>'), so one
                             model's GPU-capacity problem doesn't block the others. Skipped
                             entirely if no selected product needs a model.
 12) straiker-defend      - install/upgrade release 'straiker-defend' (argus + its
                             settings-sync daemon — charts/straiker-defend). Always runs,
                             regardless of product selection — straiker-ascend's iris calls
                             Argus's /api/v1/detect directly for several detection
                             categories, so Ascend-only installs need this too. Runs after
                             straiker-inference (needs its per-model Services) and
                             straiker-system (needs its Redis/OpenSearch/Benthos and shared
                             NodePool).
 12b) straiker-argus-v3   - install/upgrade release 'argus-v3' (the Argus v3 engine, its
                             agent-config consumer and transcript compactor —
                             charts/straiker-argus-v3). Only with --defend-engine v3 and
                             --data-layer: it runs on MSK, ElastiCache, Secrets Manager and
                             the argus-sa Pod Identity role from aws-data. Fills the
                             <cluster>/argus/v3 secret from the gateway and platform keys.
 13) straiker-ascend     - install/upgrade release 'straiker-ascend' (iris automated
                             red-teaming engine — charts/straiker-ascend: control-plane,
                             probe-worker, probe-shadow, recon-worker, report-worker, and a
                             daily assessment-cleanup CronJob). Only when 'ascend' is
                             selected. Runs after straiker-core (shared Postgres via
                             straiker-system + frontend's admin-API callback), ai-provider-
                             secrets (trial-key's BIFROST_API_KEY), and straiker-inference
                             (needs inference-thanos).
 14) tailscale-operator   - only when --edge-type tailscale is selected. Installs the
                             third-party Tailscale Kubernetes operator Helm chart, using your
                             own OAuth client ID/secret (--tailscale-oauth-client-id/-secret)
                             — stored in 'straiker-secrets'. Exposes straiker-edge's Service
                             (mode 19 below) onto your tailnet at L3.
 15) edge-infra           - only when --edge-type alb, xalb, or tailscale is selected. Runs
                             terraform/aws/edge. For alb/xalb, unconditionally creates the AWS
                             Load Balancer Controller's IAM role (phase 17, alb-controller,
                             needs this either way) — no self-signed certificate for either
                             edge type, --alb-certificate-arn is required by default for both
                             (works regardless of which AWS account/DNS provider hosts the
                             domain's zone); --alb-route53/--xalb-route53 (opt-in, per edge
                             type) auto-issue a real ACM certificate via DNS validation
                             instead — xalb's additionally creates the ExternalDNS
                             controller's IAM role (phase 18) to keep its public DNS record
                             synced, which alb has no equivalent of (internal-only). For
                             tailscale, creates cert-manager's Route53 IAM role instead (phase
                             16 needs this) — no ALB controller IAM role in this mode.
                             Optionally (--alb-provision-bastion, alb only) a tiny
                             SSM-accessible EC2 bastion for pre-handoff verification.
 16) cert-manager         - only when --edge-type tailscale is selected. Installs
                             cert-manager via its Helm chart, using the IAM role phase 15
                             (edge-infra) created, through Pod Identity. straiker-edge (mode
                             19 below) supplies the ClusterIssuer/Certificate that request a
                             real Let's Encrypt certificate for --custom-domain via Route53
                             DNS-01 — this phase only installs the controller/CRDs.
 17) alb-controller       - only when --edge-type alb or xalb is selected. Installs the AWS
                             Load Balancer Controller via its Helm chart, using the IAM role
                             phase 15 (edge-infra) created, through Pod Identity. Skips if
                             an 'alb' IngressClass already exists (ours from a prior run, or
                             a pre-existing controller on this cluster). Provides the 'alb'
                             IngressClass straiker-edge's Ingress (mode 19 below) needs.
 18) external-dns         - only when --edge-type xalb is selected with --xalb-route53.
                             Installs ExternalDNS via its Helm chart, using the IAM
                             role phase 15 (edge-infra) created, through Pod Identity, so the
                             app hostnames stay pointed at the ALB automatically. Skips if an
                             'external-dns' Deployment already exists (ours from a prior run,
                             or a pre-existing one).
 19) straiker-edge        - install/upgrade release 'straiker-edge' (charts/straiker-edge).
                             Always runs, in one of five edgeType modes (chosen via
                             --edge-type, prompted first if omitted): none (default) —
                             installs nothing, bring your own ingress/LoadBalancer;
                             internal — thin TLS edge (Caddy) routing app.<appDomain> to
                             straiker-core's frontend and defend.<appDomain> to
                             straiker-defend (502s until that phase has run, since
                             straiker-defend is now always installed too); tailscale — same
                             Caddy, but with a real cert-manager certificate for
                             --custom-domain and its Service exposed onto the tailnet at L3
                             via the operator installed in phase 14; alb — one Ingress
                             covering all routes via host-based rules, backed by a single
                             internal AWS Application Load Balancer through the AWS Load
                             Balancer Controller installed in phase 17; xalb — same as alb
                             but internet-facing, sharing an ALB with other Ingresses via
                             IngressGroup, always backed by the real certificate phase 15
                             issued.
 20) observability        - EKS only. Runs terraform/aws/observability: the Amazon CloudWatch
                             Observability add-on (Container Insights metrics incl. GPUs, and
                             every container's logs in /aws/containerinsights/<cluster>/*,
                             30-day retention; Application Signals off), CloudWatch alarms
                             (failed nodes, node CPU/memory, edge ALB 5xx, Aurora CPU and
                             capacity) and the SNS topic <cluster>-alarms. --alarm-email
                             subscribes addresses to it.

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
  # One GPU per replica, 2 replicas per model (charts/straiker-inference replicas): what the production profile needs.
  local gpu_node_count=$(( ${#models[@]} * 2 ))

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
  if [[ -n "${VPC_ID}" ]]; then
    echo " vpc_id=${VPC_ID} (bring-your-own-VPC — NAT gateway/data-transfer costs on your existing VPC aren't estimated here; only the EKS control plane + node group lines below apply)"
  fi
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
      # one per AZ otherwise. Base hourly charge only -- excludes per-GB data
      # processing. Only applies in create-mode -- bring-your-own-VPC (see
      # vpc_id above) creates no NAT gateway at all; the customer's supplied
      # subnets are expected to already have their own outbound routing.
      if [[ -z "${VPC_ID}" ]]; then
        local nat_count=1
        [[ "${PROVISION_STRATEGY}" != "min" ]] && nat_count="${az_or_zone_count}"
        # --single-nat-gateway overrides provision_strategy's NAT count (see
        # terraform/aws/eks's single_nat_gateway variable).
        [[ "${SINGLE_NAT_GATEWAY}" == "true" ]] && nat_count=1
        line_cost="$(awk -v n="${nat_count}" -v h="${hours_per_month}" 'BEGIN { printf "%.2f", n * 0.045 * h }')"
        echo " NAT gateway (${nat_count}x, base charge only, excludes data processing): \$${line_cost}/mo"
        total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"
      fi
    fi
    echo ""
  fi

  if [[ "${gpu_node_count}" -gt 0 ]]; then
    if [[ "${CLOUD_PROVIDER}" != "gke" && "$(gpu_fleet)" == "p4d" ]]; then
      # Customer (packed) fleet, one server per GPU on the chosen instance type. Rate: us-east-1 on-demand list price,
      # only for types we actually have a figure for; otherwise the node count is shown with no $/hour guess.
      local packed_itype packed_nodes packed_max packed_rate packed_max_cost
      packed_itype="$(gpu_instance_type)"
      packed_nodes="$(p4d_nodes_for "${gpu_node_count}")"
      packed_max="$(get_metadata "gpu_max_nodes")"
      packed_max="${packed_max:-4}"
      case "${packed_itype}" in
        p4d.24xlarge) packed_rate=32.77 ;;
        g6e.12xlarge) packed_rate=10.49 ;;
        g6e.4xlarge) packed_rate=3.00 ;;
        g6e.2xlarge) packed_rate=2.24 ;;
        g6e.xlarge) packed_rate=1.86 ;;
        *) packed_rate="" ;;
      esac
      if [[ -n "${packed_rate}" ]]; then
        line_cost="$(awk -v n="${packed_nodes}" -v h="${hours_per_month}" -v r="${packed_rate}" 'BEGIN { printf "%.2f", n * r * h }')"
        packed_max_cost="$(awk -v n="${packed_max}" -v h="${hours_per_month}" -v r="${packed_rate}" 'BEGIN { printf "%.2f", n * r * h }')"
        echo " GPU inference nodes (${packed_nodes}x ${packed_itype} at ~\$${packed_rate}/h, ${gpu_node_count} model servers = 2 replicas of each of: ${models[*]}): \$${line_cost}/mo (\$${packed_max_cost}/mo at the pool's ${packed_max}-node maximum)"
      else
        echo " GPU inference nodes (${packed_nodes}x ${packed_itype}, ${gpu_node_count} model servers = 2 replicas of each of: ${models[*]}): check the AWS pricing calculator for this instance type (pool grows to ${packed_max} nodes)"
      fi
    else
      # per-model fleet: one 24 GB-class GPU node per model server (thanos on g6e costs more).
      line_cost="$(awk -v n="${gpu_node_count}" -v h="${hours_per_month}" 'BEGIN { printf "%.2f", n * 1.006 * h }')"
      echo " GPU inference nodes (${gpu_node_count}x 24 GB-class GPU at ~\$1.01/h, 2 replicas of each of: ${models[*]}): \$${line_cost}/mo"
    fi
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
      --update-alb-certificate)
        UPDATE_ALB_CERTIFICATE=true
        shift
        ;;
      --alb-cert-file)
        ALB_CERT_FILE=${2:-}
        shift 2
        ;;
      --alb-key-file)
        ALB_KEY_FILE=${2:-}
        shift 2
        ;;
      --alb-chain-file)
        ALB_CHAIN_FILE=${2:-}
        shift 2
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
      --data-layer)
        DATA_LAYER=true
        shift
        ;;
      --install-tofu)
        INSTALL_TOFU=true
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
      --private-api-endpoint)
        CLUSTER_PUBLIC_ACCESS=false
        CLUSTER_ENDPOINT_EXPLICIT=true
        shift
        ;;
      --api-public-cidrs)
        CLUSTER_PUBLIC_ACCESS_CIDRS=${2:-}
        CLUSTER_ENDPOINT_EXPLICIT=true
        shift 2
        ;;
      --api-allowed-cidrs)
        CLUSTER_API_ALLOWED_CIDRS=${2:-}
        CLUSTER_ENDPOINT_EXPLICIT=true
        shift 2
        ;;
      --single-nat-gateway)
        SINGLE_NAT_GATEWAY=true
        SINGLE_NAT_GATEWAY_EXPLICIT=true
        shift
        ;;
      --vpc-id)
        VPC_ID=${2:-}
        shift 2
        ;;
      --private-subnet-ids)
        PRIVATE_SUBNET_IDS=${2:-}
        shift 2
        ;;
      --public-subnet-ids)
        PUBLIC_SUBNET_IDS=${2:-}
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
      --alarm-email)
        ALARM_EMAILS="${ALARM_EMAILS:+${ALARM_EMAILS},}${2:-}"
        shift 2
        ;;
      --admin-email)
        ADMIN_EMAIL=${2:-}
        shift 2
        ;;
      --reset-admin-password)
        RESET_ADMIN_PASSWORD=true
        shift
        ;;
      --defend-engine)
        DEFEND_ENGINE=${2:-}
        shift 2
        ;;
      --inference-profile)
        INFERENCE_PROFILE=${2:-}
        shift 2
        ;;
      --gpu-fleet)
        GPU_FLEET=${2:-}
        shift 2
        ;;
      --gpu-instance-type)
        GPU_INSTANCE_TYPE=${2:-}
        shift 2
        ;;
      --gpu-max-nodes)
        GPU_MAX_NODES=${2:-}
        shift 2
        ;;
      --gpu-capacity-reservation)
        GPU_CAPACITY_RESERVATION=${2:-}
        shift 2
        ;;
      --availability-zones)
        AVAILABILITY_ZONES_OPT=${2:-}
        shift 2
        ;;
      --inference-mode)
        INFERENCE_MODE=${2:-}
        shift 2
        ;;
      --inference-models)
        INFERENCE_MODELS=${2:-}
        shift 2
        ;;
      --saas-frontend)
        SAAS_FRONTEND=true
        shift
        ;;
      --gateway-exposure)
        GATEWAY_EXPOSURE=${2:-}
        shift 2
        ;;
      --gateway-cert-arn)
        GATEWAY_CERT_ARN=${2:-}
        shift 2
        ;;
      --gateway-domain)
        GATEWAY_DOMAIN=${2:-}
        shift 2
        ;;
      --gateway-zone-id)
        GATEWAY_ZONE_ID=${2:-}
        shift 2
        ;;
      --gateway-allowed-cidrs)
        GATEWAY_ALLOWED_CIDRS=${2:-}
        shift 2
        ;;
      --sso-type)
        SSO_TYPE=${2:-}
        shift 2
        ;;
      --sso-name)
        SSO_NAME=${2:-}
        shift 2
        ;;
      --sso-saml-metadata-url)
        SSO_SAML_METADATA_URL=${2:-}
        shift 2
        ;;
      --sso-saml-metadata-file)
        SSO_SAML_METADATA_FILE=${2:-}
        shift 2
        ;;
      --sso-oidc-issuer)
        SSO_OIDC_ISSUER=${2:-}
        shift 2
        ;;
      --sso-client-id | --sso-oidc-client-id)
        SSO_CLIENT_ID=${2:-}
        shift 2
        ;;
      --sso-email-claim)
        SSO_EMAIL_CLAIM=${2:-}
        shift 2
        ;;
      --sso-domains)
        SSO_DOMAINS=${2:-}
        shift 2
        ;;
      --sso-apple-team-id)
        SSO_APPLE_TEAM_ID=${2:-}
        shift 2
        ;;
      --sso-apple-key-id)
        SSO_APPLE_KEY_ID=${2:-}
        shift 2
        ;;
      --sso-apple-private-key-file)
        SSO_APPLE_PRIVATE_KEY_FILE=${2:-}
        shift 2
        ;;
      --allow-sso-change)
        ALLOW_SSO_CHANGE=true
        shift
        ;;
      --skip-sso-preflight)
        SKIP_SSO_PREFLIGHT=true
        shift
        ;;
      --skip-capacity-probe)
        SKIP_CAPACITY_PROBE=true
        shift
        ;;
      --rotate-admin-password)
        ROTATE_ADMIN_PASSWORD=true
        RESET_ADMIN_PASSWORD=true
        shift
        ;;
      --ses-domain)
        SES_DOMAIN=${2:-}
        shift 2
        ;;
      --ses-route53-zone-id)
        SES_ROUTE53_ZONE_ID=${2:-}
        shift 2
        ;;
      --ses-identity-arn)
        SES_IDENTITY_ARN=${2:-}
        shift 2
        ;;
      --ses-from)
        SES_FROM=${2:-}
        shift 2
        ;;
      --ses-configuration-set)
        SES_CONFIGURATION_SET=${2:-}
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
      --edge-type)
        EDGE_TYPE=${2:-}
        if [[ "${EDGE_TYPE}" != "internal" && "${EDGE_TYPE}" != "none" && "${EDGE_TYPE}" != "tailscale" && "${EDGE_TYPE}" != "alb" && "${EDGE_TYPE}" != "xalb" ]]; then
          echo "ERROR: --edge-type must be 'internal', 'none', 'tailscale', 'alb', or 'xalb', got '${2:-}'." >&2
          exit 1
        fi
        shift 2
        ;;
      --tailscale-oauth-client-id)
        TAILSCALE_OAUTH_CLIENT_ID=${2:-}
        shift 2
        ;;
      --tailscale-oauth-client-secret)
        TAILSCALE_OAUTH_CLIENT_SECRET=${2:-}
        shift 2
        ;;
      --tailscale-cluster-issuer-email)
        TAILSCALE_CLUSTER_ISSUER_EMAIL=${2:-}
        shift 2
        ;;
      --custom-domain)
        CUSTOM_ORIGIN_DOMAIN=${2:-}
        shift 2
        ;;
      --alb-certificate-arn)
        ALB_CERTIFICATE_ARN=${2:-}
        shift 2
        ;;
      --alb-provision-bastion)
        ALB_PROVISION_BASTION=true
        shift
        ;;
      --alb-subnets)
        ALB_SUBNETS=${2:-}
        shift 2
        ;;
      --alb-route53)
        ALB_ROUTE53_AUTOMATION=true
        shift
        ;;
      --xalb-route53)
        XALB_ROUTE53_AUTOMATION=true
        shift
        ;;
      --waf-rate-limit)
        WAF_RATE_LIMIT=${2:-}
        if [[ ! "${WAF_RATE_LIMIT}" =~ ^[0-9]+$ ]]; then
          echo "ERROR: --waf-rate-limit must be a whole number (0 = no rate rule), got '${2:-}'." >&2
          exit 1
        fi
        shift 2
        ;;
      --internal-lb-source-ranges)
        INTERNAL_LB_SOURCE_RANGES=${2:-}
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

  # Bring-your-own-VPC: --vpc-id/--private-subnet-ids/--public-subnet-ids
  # must be given together or not at all — a partial set almost certainly
  # means a typo'd/forgotten flag, not a deliberate half-BYO configuration.
  if [[ -n "${VPC_ID}" || -n "${PRIVATE_SUBNET_IDS}" || -n "${PUBLIC_SUBNET_IDS}" ]]; then
    if [[ -z "${VPC_ID}" || -z "${PRIVATE_SUBNET_IDS}" || -z "${PUBLIC_SUBNET_IDS}" ]]; then
      echo "ERROR: --vpc-id, --private-subnet-ids, and --public-subnet-ids must all be given together, or not at all." >&2
      exit 1
    fi
  fi
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

# EXIT handler: a command that fails under `set -e` ends the installer with no message and leaves its phase "in_progress" (seen on
# the first clean install: a ConfigMap read in platform-services). Name the failing command and function, and mark the phase
# failed so state, --status and the wrapper show it. Phases that already recorded blocked/failed, interrupts and clean exits are
# left alone (the EXIT trap only runs in the main shell, not in command substitutions).
on_exit_report() {
  local rc=$? cmd="${BASH_COMMAND}" fn="${FUNCNAME[1]:-main}"
  trap - EXIT
  [[ ${rc} -ne 0 && -n "${CURRENT_PHASE:-}" ]] || return 0
  [[ "$(get_phase_status "${CURRENT_PHASE}" 2>/dev/null || true)" == "in_progress" ]] || return 0
  local message="Phase '${CURRENT_PHASE}' stopped unexpectedly (exit ${rc}) in ${fn}: ${cmd}"
  set_phase_status "${CURRENT_PHASE}" "failed" "${message}" 2>/dev/null || true
  set_install_status "failed" "${message}" 2>/dev/null || true
  echo "ERROR: ${message}" >&2
  echo "       Re-run the same command after fixing this; the phase starts again from its beginning." >&2
  return 0
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

# Copies the .tf sources plus any static .json assets they reference via
# file() (e.g. terraform/aws/edge's alb_controller_iam_policy.json) into the
# /tmp work dir, leaving .terraform/, backend.tf, terraform.auto.tfvars, and
# any state already there untouched — so re-running a phase doesn't
# re-download providers or lose local state. The .json copy is best-effort
# (suppressed error) since most modules don't have any.
sync_terraform_workdir() {
  local src=$1 dest=$2
  mkdir -p "${dest}"
  cp -f "${src}"/*.tf "${dest}/"
  cp -f "${src}"/*.json "${dest}/" 2>/dev/null || true
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

write_data_backend_config() {
  local bucket_name=$1
  cat > "${DATA_DIR}/backend.tf" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
terraform {
  backend "s3" {
    bucket       = "${bucket_name}"
    key          = "s6r-onprem/data.tfstate"
    region       = "${AWS_REGION}"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
}

write_edge_infra_backend_config() {
  local bucket_name=$1
  cat > "${EDGE_INFRA_DIR}/backend.tf" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
terraform {
  backend "s3" {
    bucket       = "${bucket_name}"
    key          = "s6r-onprem/edge.tfstate"
    region       = "${AWS_REGION}"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
}

write_observability_backend_config() {
  local bucket_name=$1
  cat > "${OBSERVABILITY_DIR}/backend.tf" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
terraform {
  backend "s3" {
    bucket       = "${bucket_name}"
    key          = "s6r-onprem/observability.tfstate"
    region       = "${AWS_REGION}"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
}

# Renders var.image_names as a tofu-var JSON array, e.g. ["a/b","c/d"].

# Splits a comma-separated subnet-ID list, trims whitespace around each
# entry, and rejects (exit 1) any entry that ends up empty (e.g. a leading
# or doubled comma — a lone trailing comma is silently absorbed instead,
# since bash's own IFS splitting already drops a trailing empty field).
# Left uncaught, an empty entry here later fails deep inside `tofu apply`
# with a cryptic AWS API error ("InvalidID: The ID '' is not valid") on
# whichever aws_ec2_tag resource happens to land on it, rather than a clear
# message here. Echoes the normalized comma-separated list on success.
normalize_subnet_ids() {
  local csv="$1" flag_name="$2" raw id
  local -a out=()
  IFS=',' read -r -a raw <<< "${csv}"
  for id in "${raw[@]}"; do
    id="${id#"${id%%[![:space:]]*}"}"
    id="${id%"${id##*[![:space:]]}"}"
    if [[ -z "${id}" ]]; then
      echo "ERROR: ${flag_name} contains an empty entry (check for a leading/trailing/doubled comma): '${csv}'" >&2
      exit 1
    fi
    out+=("${id}")
  done
  local IFS=,
  echo "${out[*]}"
}

# Renders a comma-separated CIDR list as a tofu-var JSON array, e.g.
# ["10.0.0.0/8", "192.168.1.0/24"]. Empty input echoes nothing, so callers can
# test for "" and omit the tfvars line entirely rather than writing an empty
# list -- for cluster_endpoint_public_access_cidrs the two are very different
# (omitted = terraform's 0.0.0.0/0 default; [] = nothing can reach the
# endpoint). Validates shape only (x.x.x.x/len); AWS rejects the rest.
csv_to_tf_list() {
  local csv="$1" flag_name="$2" raw entry
  local -a out=()
  [[ -z "${csv}" ]] && return 0
  IFS=',' read -r -a raw <<< "${csv}"
  for entry in "${raw[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "${entry}" ]] && continue
    if [[ ! "${entry}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
      echo "ERROR: ${flag_name} entry '${entry}' is not a CIDR block (expected e.g. 10.0.0.0/8)." >&2
      exit 1
    fi
    out+=("\"${entry}\"")
  done
  [[ ${#out[@]} -eq 0 ]] && return 0
  local IFS=,
  echo "[${out[*]}]"
}

# The API-endpoint/NAT tfvars lines shared by write_eks_tfvars' two branches
# (bring-your-own-VPC and create-VPC). Each line is omitted rather than
# written empty when the operator said nothing, so terraform's own defaults
# stay authoritative and this installer doesn't silently re-assert them.
emit_eks_endpoint_tfvars() {
  echo "cluster_endpoint_public_access = ${CLUSTER_PUBLIC_ACCESS}"

  local public_cidrs allowed_cidrs
  public_cidrs="$(csv_to_tf_list "${CLUSTER_PUBLIC_ACCESS_CIDRS}" "--api-public-cidrs")"
  allowed_cidrs="$(csv_to_tf_list "${CLUSTER_API_ALLOWED_CIDRS}" "--api-allowed-cidrs")"
  [[ -n "${public_cidrs}" ]] && echo "cluster_endpoint_public_access_cidrs = ${public_cidrs}"
  [[ -n "${allowed_cidrs}" ]] && echo "cluster_endpoint_private_access_cidrs = ${allowed_cidrs}"

  # Only emitted when explicitly asked for -- leaving it unset keeps
  # terraform's null default, i.e. NAT count stays coupled to
  # provision_strategy exactly as before.
  [[ -n "${SINGLE_NAT_GATEWAY}" ]] && echo "single_nat_gateway = ${SINGLE_NAT_GATEWAY}"
  return 0
}

# The AZ list the cluster is built on, space-separated, in order. --availability-zones wins; otherwise the region's first
# $2 available AZs, with a --gpu-capacity-reservation's AZ moved to the front (that is where the reserved GPUs are).
# $1 = how many AZs the default list has. Prints the list; on a bad choice prints the reason to stderr and returns 1.
resolve_availability_zones() {
  local want=$1 avail az chosen="" n=0 crs res_az=""
  avail="$(aws ec2 describe-availability-zones --region "${AWS_REGION}" --filters Name=state,Values=available \
    --query 'AvailabilityZones[].ZoneName' --output text 2>/dev/null | tr '\t' ' ')"
  [[ -n "${avail// /}" ]] || { echo "Could not list the availability zones of region '${AWS_REGION}'." >&2; return 1; }
  if [[ -n "${AVAILABILITY_ZONES_OPT}" ]]; then
    local given=() seen=" "
    IFS=',' read -r -a given <<< "${AVAILABILITY_ZONES_OPT// /}"
    if (( ${#given[@]} < 2 || ${#given[@]} > 3 )); then
      echo "--availability-zones takes 2 or 3 zone names (EKS needs at least 2), got ${#given[@]}: '${AVAILABILITY_ZONES_OPT}'." >&2
      return 1
    fi
    for az in "${given[@]}"; do
      if [[ " ${avail} " != *" ${az} "* ]]; then
        echo "'${az}' is not an available Availability Zone of ${AWS_REGION}. Available: ${avail}." >&2
        return 1
      fi
      if [[ "${seen}" == *" ${az} "* ]]; then
        echo "--availability-zones lists '${az}' twice." >&2
        return 1
      fi
      seen+="${az} "
      chosen+="${az} "
    done
    echo "${chosen% }"
    return 0
  fi
  crs="${GPU_CAPACITY_RESERVATION:-$(get_metadata "gpu_capacity_reservation")}"
  if [[ -n "${crs}" ]]; then
    res_az="$(aws ec2 describe-capacity-reservations --region "${AWS_REGION}" --capacity-reservation-ids "${crs%%,*}" \
      --query 'CapacityReservations[0].AvailabilityZone' --output text 2>/dev/null || true)"
    [[ "${res_az}" == "None" || " ${avail} " != *" ${res_az} "* ]] && res_az=""
  fi
  # No reservation: the zone the pre-build capacity probe found free (select_gpu_zone) goes first.
  if [[ -z "${res_az}" ]]; then
    res_az="$(get_metadata "gpu_first_az")"
    [[ -n "${res_az}" && " ${avail} " != *" ${res_az} "* ]] && res_az=""
  fi
  [[ -n "${res_az}" ]] && { chosen="${res_az} "; n=1; }
  for az in ${avail}; do
    (( n >= want )) && break
    [[ "${az}" == "${res_az}" ]] && continue
    chosen+="${az} "
    n=$((n + 1))
  done
  echo "${chosen% }"
}

# Checks --availability-zones before anything is built: not with --vpc-id, well-formed, and not changed once the cluster exists.
validate_availability_zones_flag() {
  [[ -n "${AVAILABILITY_ZONES_OPT}" ]] || return 0
  if [[ -n "${VPC_ID}" ]]; then
    mark_phase_blocked "--availability-zones cannot be combined with --vpc-id: with your own VPC the AZs are those of the subnets you supply."
    return 1
  fi
  local azs
  if ! azs="$(resolve_availability_zones 2)"; then
    mark_phase_blocked "$(resolve_availability_zones 2 2>&1 >/dev/null)"
    return 1
  fi
  local have
  have="$(get_metadata "availability_zones" | tr ',' ' ' | xargs)"
  if [[ -n "${have}" && "$(get_phase_status eks-cluster)" == "done" && "${have}" != "${azs}" ]]; then
    mark_phase_blocked "The cluster already runs in ${have}; its Availability Zones cannot be changed afterwards. Re-run without --availability-zones, or pass the same list."
    return 1
  fi
  log "Availability Zones (in order): ${azs}"
}

write_eks_tfvars() {
  # Bring-your-own-VPC: AZs are derived from the supplied subnets by
  # terraform/aws/eks itself (see its locals.tf), so the live
  # describe-availability-zones resolution below is not just redundant here,
  # it would be actively wrong to still gate on var.availability_zones.
  if [[ -n "${VPC_ID}" ]]; then
    local priv_json pub_json
    priv_json="$(echo "${PRIVATE_SUBNET_IDS}" | sed 's/,/", "/g; s/^/["/; s/$/"]/')"
    pub_json="$(echo "${PUBLIC_SUBNET_IDS}" | sed 's/,/", "/g; s/^/["/; s/$/"]/')"
    cat > "${EKS_DIR}/terraform.auto.tfvars" <<EOF
# Generated by scripts/install-straiker.sh — safe to delete between runs.
region             = "${AWS_REGION}"
cluster_name       = "${CLUSTER_NAME}"
provision_strategy = "${PROVISION_STRATEGY}"
vpc_id             = "${VPC_ID}"
private_subnet_ids = ${priv_json}
public_subnet_ids  = ${pub_json}
byo_vpc_confirm    = true
EOF
    emit_eks_endpoint_tfvars >> "${EKS_DIR}/terraform.auto.tfvars"
    return
  fi

  # provision_strategy=max gets a 3rd AZ registered (matching this module's
  # own availability_zones variable description: "3 for maximum
  # resilience") -- min/ha both still register 2 (EKS's hard minimum for
  # the control plane; provision_strategy=min just confines the node
  # group/NAT/Karpenter discovery to the first of the two, see
  # terraform/aws/eks/locals.tf).
  local az_count=2
  [[ "${PROVISION_STRATEGY}" == "max" ]] && az_count=3

  local azs az_json az1
  if ! azs="$(resolve_availability_zones "${az_count}")"; then
    mark_phase_blocked "$(resolve_availability_zones "${az_count}" 2>&1 >/dev/null)"
    return
  fi

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
  emit_eks_endpoint_tfvars >> "${EKS_DIR}/terraform.auto.tfvars"
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
  validate_availability_zones_flag || return
  preflight_gpu_quota || return
  require_command tofu
  require_terraform_dir "${TFBE_SRC}" || return
  sync_terraform_workdir "${TFBE_SRC}" "${TFBE_DIR}"

  tofu_init "${TFBE_DIR}" -upgrade -input=false

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

  tofu_init "${GCP_TFBE_DIR}" -upgrade -input=false

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

# Checks that one bring-your-own private subnet actually has outbound routing,
# which is the precondition terraform/aws/eks's own vpc_id variable documents
# but nothing has ever verified. Echoes the default route's target on success;
# on failure echoes a human-readable reason and returns 1.
#
# Worth checking statically rather than by probing: a deleted NAT gateway
# leaves its 0.0.0.0/0 route behind in state "blackhole" rather than removing
# it, so "a default route exists" is not sufficient on its own.
byo_private_subnet_egress() {
  local subnet_id=$1
  local rt_id routes state target

  # Explicit subnet association first; a subnet with none inherits the VPC's
  # main route table.
  rt_id="$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
    --filters "Name=association.subnet-id,Values=${subnet_id}" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
  if [[ -z "${rt_id}" || "${rt_id}" == "None" ]]; then
    rt_id="$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)"
  fi
  if [[ -z "${rt_id}" || "${rt_id}" == "None" ]]; then
    echo "could not resolve a route table for subnet ${subnet_id} (needs ec2:DescribeRouteTables)"
    return 1
  fi

  routes="$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
    --route-table-ids "${rt_id}" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[State,NatGatewayId,TransitGatewayId,GatewayId,NetworkInterfaceId]' \
    --output text 2>/dev/null || true)"
  if [[ -z "${routes}" || "${routes}" == "None" ]]; then
    echo "subnet ${subnet_id} (route table ${rt_id}) has no 0.0.0.0/0 route"
    return 1
  fi

  state="$(awk 'NR==1{print $1}' <<< "${routes}")"
  target="$(awk 'NR==1{for (i=2; i<=NF; i++) if ($i != "None") { print $i; exit }}' <<< "${routes}")"
  if [[ "${state}" == "blackhole" ]]; then
    echo "subnet ${subnet_id} (route table ${rt_id}) has a 0.0.0.0/0 route in state 'blackhole' — its target ${target:-(unknown)} no longer exists"
    return 1
  fi

  echo "${target:-unknown}"
  return 0
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

  # Bring-your-own-VPC preflight: fail fast with a clear message rather than
  # deep inside `tofu apply` — this is exactly the class of gap the feature
  # exists to route around (an SCP/IAM policy denying more than just
  # ec2:CreateVpc), so it deserves its own explicit check.
  if [[ -n "${VPC_ID}" ]]; then
    if ! aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${AWS_REGION}" >/dev/null 2>&1; then
      mark_phase_blocked "Could not describe VPC '${VPC_ID}' in ${AWS_REGION} — either it doesn't exist, or your AWS credentials lack ec2:DescribeVpcs."
      return
    fi
    local byo_priv_ids byo_pub_ids
    IFS=',' read -r -a byo_priv_ids <<< "${PRIVATE_SUBNET_IDS}"
    IFS=',' read -r -a byo_pub_ids <<< "${PUBLIC_SUBNET_IDS}"
    if ! aws ec2 describe-subnets --subnet-ids "${byo_priv_ids[@]}" "${byo_pub_ids[@]}" --region "${AWS_REGION}" >/dev/null 2>&1; then
      mark_phase_blocked "Could not describe one or more of the supplied subnet IDs in ${AWS_REGION} — either an ID is wrong, or your AWS credentials lack ec2:DescribeSubnets."
      return
    fi
    if ! aws ec2 create-tags --resources "${byo_priv_ids[0]}" --tags Key=straiker-byo-vpc-preflight,Value=ok --region "${AWS_REGION}" >/dev/null 2>&1; then
      mark_phase_blocked "Your AWS credentials can describe subnet '${byo_priv_ids[0]}' but cannot tag it (ec2:CreateTags denied). Bring-your-own-VPC needs CreateTags/DeleteTags on the supplied subnets to apply required kubernetes.io/role/* and karpenter.sh/discovery tags."
      return
    fi
    aws ec2 delete-tags --resources "${byo_priv_ids[0]}" --tags Key=straiker-byo-vpc-preflight --region "${AWS_REGION}" >/dev/null 2>&1 || true

    # Outbound routing. This module creates no NAT gateway in BYO mode, so the
    # supplied subnets having their own egress is a precondition -- documented
    # on terraform/aws/eks's vpc_id variable, but until now never checked.
    # Unverified it fails silently and late: the cluster comes up, then nodes
    # degrade roughly an hour later when the VPC CNI can no longer reach STS to
    # refresh its IRSA credentials, pods get evicted as the nodes go NotReady,
    # and nothing in the install output ever points at the actual cause.
    local byo_subnet byo_egress
    for byo_subnet in "${byo_priv_ids[@]}"; do
      if ! byo_egress="$(byo_private_subnet_egress "${byo_subnet}")"; then
        mark_phase_blocked "Bring-your-own-VPC preflight: ${byo_egress}.

This installer creates no NAT gateway when --vpc-id is set — your private subnets must provide their own outbound routing. Straiker cannot install or upgrade without it: the artifact mirror reads Straiker's source registry and bucket in us-east-1, which no VPC endpoint in ${AWS_REGION} can reach (interface and gateway endpoints are regional).

Fix the route in your VPC, then re-run. For the full set of destinations to allow if egress is filtered, see doc/egress-allowlist.md."
        return
      fi
      log "  ${byo_subnet}: outbound 0.0.0.0/0 via ${byo_egress}"
    done
  fi

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

  # Endpoint-exposure drift guard. `tofu apply` below runs -auto-approve, so
  # nobody ever sees the plan -- without this, a customer who took their API
  # server off the internet by hand (console/CLI, outside this installer) gets
  # it silently put back the next time this phase runs, which is a security
  # regression they would have no reason to look for. Refuse instead, and say
  # exactly how to make the change stick. Only fires in the reduce-exposure
  # direction; a live cluster that is MORE open than requested is what this
  # phase is legitimately here to fix.
  if [[ "${CLUSTER_PUBLIC_ACCESS}" == "true" ]]; then
    local live_public_access
    live_public_access="$(aws eks describe-cluster \
      --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --query 'cluster.resourcesVpcConfig.endpointPublicAccess' \
      --output text 2>/dev/null || true)"
    if [[ "${live_public_access}" == "False" || "${live_public_access}" == "false" ]]; then
      mark_phase_blocked "Cluster '${CLUSTER_NAME}' currently has PUBLIC API access disabled, but this install is configured for a public endpoint — applying would silently re-expose the Kubernetes API to the internet.

If the private-only endpoint is intended (it usually is, once set by hand), re-run with:
  --private-api-endpoint --api-allowed-cidrs <your-corporate-CIDRs>
That records the choice in ~/.straiker/install.json so every later run preserves it.

If public access really should come back, clear the guard explicitly:
  aws eks update-cluster-config --name ${CLUSTER_NAME} --region ${AWS_REGION} \\
    --resources-vpc-config endpointPublicAccess=true
then re-run this phase."
      return
    fi
  fi

  tofu_init "${EKS_DIR}" -upgrade -input=false -migrate-state -force-copy
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

  tofu_init "${GKE_DIR}" -upgrade -input=false -migrate-state -force-copy
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
    tofu_init "${EKS_DIR}" -upgrade -input=false -migrate-state -force-copy

    cluster_name="$(tofu -chdir="${EKS_DIR}" output -raw cluster_name 2>/dev/null || echo "")"
    queue_name="$(tofu -chdir="${EKS_DIR}" output -raw karpenter_queue_name 2>/dev/null || echo "")"
    if [[ -z "${cluster_name}" || -z "${queue_name}" ]]; then
      mark_phase_blocked "Could not read cluster_name/karpenter_queue_name from Terraform state either. Run phase 'eks-cluster' (add --rerun-phase if it's marked done) first."
      return
    fi
    set_metadata "cluster_name" "${cluster_name}"
    set_metadata "karpenter_queue_name" "${queue_name}"
  fi

  # The chart requires one replica per node (anti-affinity) and spreads them across zones.
  # --provision-strategy min has a single system node, so a second replica can never
  # schedule and the rollout deadlocks. Run one replica there.
  local karpenter_replicas=2
  [[ "${PROVISION_STRATEGY}" == "min" ]] && karpenter_replicas=1

  helm upgrade --install karpenter "oci://public.ecr.aws/karpenter/karpenter" \
    --version "${KARPENTER_VERSION}" \
    --namespace "${KARPENTER_NAMESPACE}" \
    --create-namespace \
    --set "replicas=${karpenter_replicas}" \
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
    tofu_init "${GKE_DIR}" -upgrade -input=false -migrate-state -force-copy

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

  tofu_init "${ARTIFACTS_DIR}" -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${ARTIFACTS_DIR}" apply -auto-approve -input=false \
    -var="region=${AWS_REGION}" \
    -var="prefix=${TF_PREFIX}" \
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="namespace=${INFRA_NAMESPACE}" \
    -var="workload_namespace=${INFRA_NAMESPACE}" \
    -var="workload_service_account_names=[\"${INFERENCE_SERVICE_ACCOUNT}\", \"${DEFEND_SERVICE_ACCOUNT}\"]" \
    -var="bedrock_mode=$([ "${AI_PROVIDER_MODE}" = "bedrock" ] && echo true || echo false)" \
    -var="bifrost_service_account_name=${BIFROST_SERVICE_ACCOUNT}"

  local models_bucket ecr_registry hauler_role_arn workload_role_arn bedrock_role_arn
  models_bucket="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw models_bucket_name)"
  ecr_registry="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw ecr_registry)"
  hauler_role_arn="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw hauler_role_arn)"
  workload_role_arn="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw workload_role_arn)"
  bedrock_role_arn="$(tofu -chdir="${ARTIFACTS_DIR}" output -raw bedrock_role_arn 2>/dev/null || true)"

  set_metadata "models_bucket" "${models_bucket}"
  set_metadata "ecr_registry" "${ecr_registry}"
  set_metadata "hauler_role_arn" "${hauler_role_arn}"
  set_metadata "workload_role_arn" "${workload_role_arn}"
  [[ -n "${bedrock_role_arn}" ]] && set_metadata "bedrock_role_arn" "${bedrock_role_arn}"
}

# AWS-managed data tier (opt-in via --data-layer). Runs after aws-artifacts:
# needs the cluster (Pod Identity associations) and the bootstrap bucket.
phase_aws_data() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    log "--data-layer not set — skipping AWS data tier."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    mark_phase_blocked "--data-layer is AWS-only."
    return
  fi
  if [[ -z "${AWS_REGION}" ]]; then
    mark_phase_blocked "AWS region is required. Use --aws-region, AWS_REGION, or configure the AWS CLI."
    return
  fi
  if [[ "${DEFEND_ENGINE}" == "v3" ]]; then
    preflight_argus_v3_bedrock || return
  fi

  require_command aws
  require_command tofu
  require_terraform_dir "${DATA_SRC}" || return
  sync_terraform_workdir "${DATA_SRC}" "${DATA_DIR}"

  local bucket_name
  bucket_name="$(get_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    bucket_name="$(resolve_bucket_name)"
  fi
  if ! aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
    mark_phase_blocked "Bootstrap bucket '${bucket_name}' not found. Run phase 'eks-tfbe' first."
    return
  fi

  if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    mark_phase_blocked "EKS cluster '${CLUSTER_NAME}' not found in ${AWS_REGION}. Run with --install-eks to provision one, or pass --cluster-name matching your existing cluster."
    return
  fi

  # VPC + private subnets come from the live cluster so this works for both our
  # own VPC and bring-your-own. Private = tagged internal-elb (set by eks-cluster
  # and required of BYO subnets); fall back to every cluster subnet if untagged.
  local vpc_id subnet_ids
  vpc_id="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
  subnet_ids="$(aws ec2 describe-subnets --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
    --query 'Subnets[].SubnetId' --output json)"
  if [[ "${subnet_ids}" == "[]" ]]; then
    subnet_ids="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --query 'cluster.resourcesVpcConfig.subnetIds' --output json)"
  fi

  # Preflight: MSK/EFS/Aurora need >=2 AZs; Aurora engine version must exist in the region.
  local azs_distinct
  azs_distinct="$(aws ec2 describe-subnets --region "${AWS_REGION}" --subnet-ids $(echo "${subnet_ids}" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))') \
    --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')"
  if [[ "${azs_distinct}" -lt 2 ]]; then
    mark_phase_blocked "The data tier needs private subnets in at least 2 AZs (found ${azs_distinct})."
    return
  fi
  # Default: the newest Aurora PostgreSQL 17.x in this region (the SaaS regions run 17.11). An existing
  # cluster ignores later version changes (minor upgrades are applied by AWS). Set AURORA_ENGINE_VERSION to pin one.
  local aurora_ver="${AURORA_ENGINE_VERSION:-}"
  if [[ -z "${aurora_ver}" ]]; then
    aurora_ver="$(aws rds describe-db-engine-versions --engine aurora-postgresql --region "${AWS_REGION}" \
      --query 'DBEngineVersions[?starts_with(EngineVersion, `17.`)].EngineVersion' --output text 2>/dev/null \
      | tr '\t' '\n' | sort -V | tail -1)"
    aurora_ver="${aurora_ver:-17.11}"
  fi
  if [[ -z "$(aws rds describe-db-engine-versions --engine aurora-postgresql --engine-version "${aurora_ver}" \
      --region "${AWS_REGION}" --query 'DBEngineVersions[0].EngineVersion' --output text 2>/dev/null | grep -v '^None$')" ]]; then
    mark_phase_blocked "Aurora PostgreSQL ${aurora_ver} is not available in ${AWS_REGION}. List: aws rds describe-db-engine-versions --engine aurora-postgresql --region ${AWS_REGION} --query 'DBEngineVersions[].EngineVersion'; then set AURORA_ENGINE_VERSION."
    return
  fi

  write_data_backend_config "${bucket_name}"

  # platform-sa grants follow the services being installed: databridge delivers into customer
  # accounts (sts:AssumeRole), connect sends email (SES).
  local platform_assume_roles=false platform_ses_send=false
  [[ " ${PLATFORM_SERVICES} " == *" databridge "* ]] && platform_assume_roles=true
  [[ " ${PLATFORM_SERVICES} " == *" connect "* ]] && platform_ses_send=true

  # SaaS frontend backends: remembered, one-way (a later run without the flag must not make Terraform destroy them).
  [[ "${SAAS_FRONTEND}" == "true" ]] && set_metadata "saas_frontend" "true"
  local saas_frontend_on=false saas_frontend_identity=""
  if [[ "$(get_metadata "saas_frontend")" == "true" ]]; then
    saas_frontend_on=true
    saas_frontend_identity='"frontend": {
      "namespace": "'"${INFRA_NAMESPACE}"'",
      "service_account": "straiker-frontend",
      "saas_frontend_data": true
    },'
  fi

  # Argus v3 engine role (chart straiker-argus-v3's ServiceAccount): Bedrock for its context reviewer. Same grant as the SaaS
  # argus pods: the inference profile, the foundation model behind it, and the account's default Bedrock project (the
  # OpenAI-compatible Responses path authorizes against the project).
  local aws_account_id argus_v3_arns="" bedrock_profile
  aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
  for bedrock_profile in ${ARGUS_V3_BEDROCK_PROFILES}; do
    argus_v3_arns+="\"arn:aws:bedrock:${AWS_REGION}:${aws_account_id}:inference-profile/${bedrock_profile}\", \"arn:aws:bedrock:*::foundation-model/${bedrock_profile#*.}\", "
  done
  argus_v3_arns+="\"arn:aws:bedrock:${AWS_REGION}:${aws_account_id}:project/default\""

  # Pod Identity role for the data-bootstrap Jobs (chart straiker-data's ServiceAccount).
  cat > "${DATA_DIR}/terraform.auto.tfvars.json" <<EOF
{
  "pod_identities": {
    ${saas_frontend_identity}
    "data-bootstrap": {
      "namespace": "${INFRA_NAMESPACE}",
      "service_account": "straiker-data",
      "msk_clusters": ["bus"]
    },
    "platform": {
      "namespace": "${INFRA_NAMESPACE}",
      "service_account": "platform-sa",
      "msk_clusters": ["bus"],
      "s3_read": ["grid-artifacts"],
      "secret_prefixes_rw": ["${CLUSTER_NAME}/platform/"],
      "assume_roles": ${platform_assume_roles},
      "ses_send": ${platform_ses_send}
    },
    "grid-ingest": {
      "namespace": "${INFRA_NAMESPACE}",
      "service_account": "grid-ingest",
      "msk_clusters": ["bus"]
    },
    "eso": {
      "namespace": "${ESO_NAMESPACE}",
      "service_account": "${ESO_SERVICE_ACCOUNT}",
      "secret_prefixes_read": ["${CLUSTER_NAME}/"],
      "aurora_master_secret": true
    },
    "api-gateway": {
      "namespace": "${INFRA_NAMESPACE}",
      "service_account": "straiker-api-gateway-sa",
      "secret_keys": ["platform/api-gateway"],
      "secret_prefixes_read": ["${CLUSTER_NAME}/platform/integration/keys/"],
      "dynamodb_query": ["environment"]
    },
    "argus-v3": {
      "namespace": "${INFRA_NAMESPACE}",
      "service_account": "argus-sa",
      "msk_clusters": ["bus"],
      "secret_keys": ["argus/v3"],
      "s3_read": ["grid-artifacts"],
      "s3_write": ["grid-artifacts"],
      "bedrock_invoke": [${argus_v3_arns}]
    }
  },
  "secrets": {
    "platform/shared": {
      "description": "Shared service keys and bootstrap admin login (Secret straiker-secrets); synced to K8s by External Secrets",
      "generated_keys": [$(printf '"%s",' ${SHARED_SECRET_PROPS} | sed 's/,$//')]
    },
    "frontend/auth": {
      "description": "Frontend session signing key; synced to K8s by External Secrets",
      "generated_keys": ["SESSION_SIGNING_KEY"],
      "password_length": 64
    },
    "argus/session": {
      "description": "Defend (Argus) session secret key; synced to K8s by External Secrets",
      "generated_keys": ["SYS__ARGUS_SESSION_SECRET_KEY"],
      "password_length": 64
    },
    "platform/keys": {
      "description": "Platform-internal service-to-service key; synced to K8s by External Secrets",
      "generated_keys": ["PLATFORM_INTERNAL_S2S_API_KEY"],
      "password_length": 48
    },
    "clickhouse/credentials": {
      "description": "ClickHouse user passwords (admin, grid_query_ro, ...); synced to K8s by External Secrets",
      "generated_keys": [$(printf '"%s",' ${CLICKHOUSE_PASSWORD_USERS} | sed 's/,$//')]
    },
    "db/passwords": {
      "description": "Aurora role passwords (foundation, registry, ...); synced to K8s by External Secrets",
      "generated_keys": [$(printf '"%s",' ${DB_PASSWORD_ROLES} | sed 's/,$//')]
    },
    "platform/api-gateway": {
      "description": "api-gateway key bundle; PLATFORM_VALIDATE_KEY and SYS__ARGUS_INTERNAL_S2S_KEY are shared with foundation/registry/argus",
      "generated_keys": ["PLATFORM_VALIDATE_KEY", "PAT_EXCHANGE_ASSERTION_SECRET", "SYS__ARGUS_INTERNAL_S2S_KEY", "FOUNDATION_API_KEY"]
    },
    "argus/v3": {
      "description": "Argus v3 engine bundle (Secrets Manager source); the two service keys are copied in by the installer so they match the gateway and platform values",
      "generated_keys": ["SYS__INFERENCE_API_KEY"]
    }
  }
}
EOF

  # OpenSearch VPC domains need the service-linked role. It exists once any domain was created in the account;
  # decided once and remembered (a later "exists" must not make Terraform destroy a role it created).
  local os_slr
  os_slr="$(get_metadata "opensearch_create_slr")"
  if [[ -z "${os_slr}" ]]; then
    if aws iam get-role --role-name AWSServiceRoleForAmazonOpenSearchService >/dev/null 2>&1; then os_slr=false; else os_slr=true; fi
    set_metadata "opensearch_create_slr" "${os_slr}"
  fi

  remember_sso_settings || return
  TF_VAR_cognito_identity_providers="$(sso_identity_providers_json)"
  export TF_VAR_cognito_identity_providers

  remember_ses_settings || return
  TF_VAR_ses_domains="$(ses_domains_json)"
  TF_VAR_ses_existing="$(ses_existing_json)"
  export TF_VAR_ses_domains TF_VAR_ses_existing
  if [[ "${saas_frontend_on}" == "true" ]]; then TF_VAR_saas_frontend='{}'; else TF_VAR_saas_frontend='null'; fi
  export TF_VAR_saas_frontend
  # Cognito needs its service-linked role (email.cognito-idp.amazonaws.com) to send through SES. Create it only when the
  # account has none; when it exists, keep creating it only if THIS install's Terraform state owns it (otherwise a later
  # "exists" would make Terraform destroy a role it created, and an unowned one would fail with "has been taken").
  local cog_slr cog_role_exists=false cog_in_state=false
  aws iam get-role --role-name AWSServiceRoleForAmazonCognitoIdpEmailService >/dev/null 2>&1 && cog_role_exists=true
  tofu -chdir="${DATA_DIR}" state list 2>/dev/null | grep -q '^aws_iam_service_linked_role\.cognito_email' && cog_in_state=true
  if [[ "${cog_role_exists}" == true && "${cog_in_state}" != true ]]; then cog_slr=false; else cog_slr=true; fi
  set_metadata "cognito_create_email_slr" "${cog_slr}"

  # $1 = cognito_use_ses (true once the SES identity is verified).
  data_apply() {
    tofu -chdir="${DATA_DIR}" apply -auto-approve -input=false \
      -var="region=${AWS_REGION}" \
      -var="cluster_name=${CLUSTER_NAME}" \
      -var="vpc_id=${vpc_id}" \
      -var="private_subnet_ids=${subnet_ids}" \
      -var="provision_strategy=${PROVISION_STRATEGY}" \
      -var="create_opensearch_service_linked_role=${os_slr}" \
      -var="create_cognito_email_service_linked_role=${cog_slr}" \
      -var="cognito_use_ses=$1" \
      -var="cognito_callback_urls=[\"$(app_origin)/login/oidc/callback\"]" \
      -var="aurora={engine_version=\"${aurora_ver}\",parameter_group_family=\"aurora-postgresql${aurora_ver%%.*}\"}"
  }

  tofu_init "${DATA_DIR}" -upgrade -input=false -migrate-state -force-copy
  local use_ses=false
  ses_identity_verified && use_ses=true
  data_apply "${use_ses}"
  if [[ -n "$(get_metadata "ses_existing_arn")" && "${use_ses}" != "true" ]]; then
    log "The customer's SES identity $(get_metadata "ses_existing_arn") is not verified for sending: Cognito keeps its default sender; fix the identity, then re-run phase aws-data."
  fi

  # First run: SES was just created. Wait for its DNS records to verify (unless the zone still needs delegating),
  # then switch Cognito's mail to it; otherwise a later run of this phase does the switch.
  if [[ -n "$(get_metadata "ses_domain")" && "${use_ses}" != "true" ]]; then
    if [[ "$(get_metadata "ses_zone_mode")" == "create" ]]; then
      log "SES domain $(get_metadata "ses_domain") is not verified yet: delegate its Route53 name servers from the parent zone, then re-run phase aws-data to switch Cognito to SES."
    else
      log "Waiting for SES to verify $(get_metadata "ses_domain") (up to 10 minutes)..."
      local ses_try
      for ses_try in $(seq 1 40); do
        ses_identity_verified && break
        sleep 15
      done
      if ses_identity_verified; then
        data_apply true
      else
        log "SES has not verified $(get_metadata "ses_domain") yet; re-run phase aws-data later to switch Cognito to SES."
      fi
    fi
  fi

  out() { tofu -chdir="${DATA_DIR}" output -raw "$1" 2>/dev/null || true; }
  set_metadata "aurora_endpoint" "$(out aurora_endpoint)"
  set_metadata "aurora_reader_endpoint" "$(out aurora_reader_endpoint)"
  set_metadata "aurora_port" "$(out aurora_port)"
  set_metadata "aurora_master_secret_arn" "$(out aurora_master_secret_arn)"
  # Every other Aurora cluster ("ascend", ...) as aurora_<key>_endpoint / _reader_endpoint /
  # _master_secret_arn; "platform" keeps the original keys above.
  local aurora_clusters_json ck cf aurora_others
  aurora_clusters_json="$(tofu -chdir="${DATA_DIR}" output -json aurora_clusters 2>/dev/null || echo '{}')"
  aurora_others="$(printf '%s' "${aurora_clusters_json}" | python3 -c 'import json,sys; print(" ".join(k for k in json.load(sys.stdin) if k != "platform"))' 2>/dev/null || true)"
  set_metadata "aurora_other_clusters" "${aurora_others}"

  # Static cluster parameters (shared_preload_libraries, rds.logical_replication) only take effect
  # after a reboot. A new cluster is created with them, so nothing is pending; an existing one that
  # just got the parameter group reports "pending-reboot", and its instances are rebooted here,
  # readers first and the writer last (about a minute of writer downtime).
  local rb_cid rb_inst rb_status rb_try
  for rb_cid in $(printf '%s' "${aurora_clusters_json}" | python3 -c 'import json,sys; print(" ".join(v.get("id","") for v in json.load(sys.stdin).values()))' 2>/dev/null || true); do
    for rb_inst in \
      $(aws rds describe-db-clusters --db-cluster-identifier "${rb_cid}" --region "${AWS_REGION}" --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`false`].DBInstanceIdentifier' --output text 2>/dev/null || true) \
      $(aws rds describe-db-clusters --db-cluster-identifier "${rb_cid}" --region "${AWS_REGION}" --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' --output text 2>/dev/null || true); do
      rb_status=""
      for rb_try in 1 2 3 4 5 6 7 8 9 10 11 12; do
        rb_status="$(aws rds describe-db-instances --db-instance-identifier "${rb_inst}" --region "${AWS_REGION}" \
          --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' --output text 2>/dev/null || true)"
        [[ "${rb_status}" == "applying" ]] || break
        sleep 10
      done
      if [[ "${rb_status}" == "pending-reboot" ]]; then
        log "Rebooting Aurora instance '${rb_inst}' to apply static cluster parameters..."
        aws rds reboot-db-instance --db-instance-identifier "${rb_inst}" --region "${AWS_REGION}" >/dev/null
        aws rds wait db-instance-available --db-instance-identifier "${rb_inst}" --region "${AWS_REGION}"
      fi
    done
  done

  for ck in ${aurora_others}; do
    for cf in endpoint reader_endpoint master_secret_arn; do
      set_metadata "aurora_${ck}_${cf}" "$(printf '%s' "${aurora_clusters_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["'"${ck}"'"]["'"${cf}"'"])' 2>/dev/null || true)"
    done
  done
  set_metadata "data_redis_endpoint" "$(tofu -chdir="${DATA_DIR}" output -json cache_endpoints 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("main") or next(iter(d.values()), {}); print(c.get("address",""))' 2>/dev/null || true)"
  # Node-based Valkey group for iris (SaaS shape); empty when the stack predates it.
  set_metadata "iris_redis_endpoint" "$(tofu -chdir="${DATA_DIR}" output -json redis_replication_groups 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("iris",{}).get("primary_endpoint",""))' 2>/dev/null || true)"
  set_metadata "iris_redis_secret_name" "$(tofu -chdir="${DATA_DIR}" output -json redis_replication_groups 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("iris",{}).get("secret_name",""))' 2>/dev/null || true)"
  set_metadata "opensearch_endpoint" "$(tofu -chdir="${DATA_DIR}" output -json opensearch_domains 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("main",{}).get("endpoint",""))' 2>/dev/null || true)"
  set_metadata "opensearch_secret_name" "$(tofu -chdir="${DATA_DIR}" output -json opensearch_domains 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("main",{}).get("secret_name",""))' 2>/dev/null || true)"
  local cognito_json
  cognito_json="$(tofu -chdir="${DATA_DIR}" output -json cognito_pools 2>/dev/null || echo '{}')"
  for cf in pool_id issuer client_id secret_name admin_secret_name saml_acs_url entity_id oidc_redirect_uri; do
    set_metadata "cognito_${cf}" "$(printf '%s' "${cognito_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("main",{}).get("'"${cf}"'",""))' 2>/dev/null || true)"
  done
  write_sso_handoff
  if [[ "${saas_frontend_on}" == "true" ]]; then
    local saas_json
    saas_json="$(tofu -chdir="${DATA_DIR}" output -json saas_frontend 2>/dev/null || echo '{}')"
    for cf in dynamodb_table_name dynamodb_guardrails_table_name audit_logs_stream; do
      set_metadata "saas_${cf}" "$(printf '%s' "${saas_json}" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("'"${cf}"'",""))' 2>/dev/null || true)"
    done
  fi
  local ses_json
  ses_json="$(tofu -chdir="${DATA_DIR}" output -json ses_domains 2>/dev/null || echo '{}')"
  set_metadata "ses_sender" "$(printf '%s' "${ses_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("main",{}).get("sender",""))' 2>/dev/null || true)"
  if [[ -n "$(get_metadata "ses_existing_arn")" ]]; then
    set_metadata "ses_sender" "$(get_metadata "ses_from")"
  fi
  set_metadata "ses_name_servers" "$(printf '%s' "${ses_json}" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("main",{}).get("name_servers",[])))' 2>/dev/null || true)"
  set_metadata "msk_cluster_arn" "$(tofu -chdir="${DATA_DIR}" output -json msk_cluster_arns 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("bus") or next(iter(d.values()), ""))' 2>/dev/null || true)"
  set_metadata "efs_file_system_id" "$(tofu -chdir="${DATA_DIR}" output -json efs_file_system_ids 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("models") or next(iter(d.values()), ""))' 2>/dev/null || true)"
  set_metadata "grid_artifacts_bucket" "$(tofu -chdir="${DATA_DIR}" output -json s3_bucket_names 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("grid-artifacts",""))' 2>/dev/null || true)"
  set_metadata "dynamodb_environment_table" "$(tofu -chdir="${DATA_DIR}" output -json dynamodb_table_names 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("environment",""))' 2>/dev/null || true)"
  set_metadata "data_kms_key_arn" "$(tofu -chdir="${DATA_DIR}" output -json kms_key_arns 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data",""))' 2>/dev/null || true)"
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

  tofu_init "${GCP_ARTIFACTS_DIR}" -upgrade -input=false -migrate-state -force-copy
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
fetch_customer_sku_bearer() {
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

    local artifact_chart_ref="${HELM_REPO_NAME}/${ARTIFACT_CHART_NAME}"
    local local_artifact_chart="${REPO_ROOT}/charts/${ARTIFACT_CHART_NAME}"
    # Prefer the in-workspace chart when present so local fixes apply immediately
    # during installer development/testing; fall back to the published repo
    # chart for bundle-only installs.
    if [[ -d "${local_artifact_chart}" ]]; then
      artifact_chart_ref="${local_artifact_chart}"
      log "Using local artifact chart at '${artifact_chart_ref}'."
    else
      helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
      helm repo update "${HELM_REPO_NAME}" >/dev/null
    fi

    kubectl create namespace "${INFRA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    local credential_json
    credential_json="$(python3 -c 'import json,sys; print(json.dumps({"api_key": sys.argv[1], "customer_email": sys.argv[2]}))' "${STRAIKER_CUSTOMER_KEY}" "$(straiker_customer_email)")"
    kubectl create secret generic "${STRAIKER_CREDENTIAL_SECRET_NAME}" \
      --namespace "${INFRA_NAMESPACE}" \
      --from-literal="key.json=${credential_json}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    local customer_sku
    customer_sku="$(fetch_customer_sku_bearer)"
    log "Detected customer sku '${customer_sku}' from credential (drives which images are attempted)."

    # Job.spec.template is immutable in Kubernetes — if a Job from a previous
    # attempt already exists (e.g. its pod got stuck Pending on a taint before
    # this chart had the right toleration), `helm upgrade` cannot patch it in
    # place; it would just silently leave the stale Job/pod as-is. Delete first
    # so the upgrade below always creates a fresh Job from the current template.
    kubectl delete job straiker-artifact-image-mirror straiker-artifact-model-sync \
      --namespace "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null

    local artifact_cmd=(
      helm upgrade --install "${ARTIFACT_RELEASE}" "${artifact_chart_ref}"
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

  ensure_multiarch_images
}

# Opt-in, off by default (nothing changes for existing installs). Set
#   MULTIARCH_OVERRIDES="<repo>:<tag>=<upstream-ref> [...]"   (space-separated)
# e.g. "maximhq/bifrost:v1.6.7=docker.io/maximhq/bifrost:v1.6.7".
# Some images in the Straiker artifact mirror are single-arch (amd64) while this
# cluster's shared pool is arm64 (Graviton), so those pods die with "exec format
# error". Once the mirror Job has finished, any listed image whose copy in THIS
# account's ECR lacks arm64 is replaced by the full multi-arch index copied
# straight from the upstream ref. Only this account's ECR is written; the Straiker
# mirror is untouched. Re-applied on every artifacts-sync pass, because re-running
# the mirror Job copies the single-arch image back over it. Needs `crane` locally.
ensure_multiarch_images() {
  [[ -n "${MULTIARCH_OVERRIDES:-}" ]] || return 0
  if ! command -v crane >/dev/null 2>&1; then
    log "WARN  MULTIARCH_OVERRIDES is set but 'crane' is not installed (brew install crane); skipping the multi-arch fix."
    return 0
  fi

  local ecr_registry registry_prefixed entry dest_ref upstream archs
  ecr_registry="$(get_metadata "ecr_registry")"
  [[ -n "${ecr_registry}" ]] || return 0
  registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"
  aws ecr get-login-password --region "${AWS_REGION}" \
    | crane auth login "${ecr_registry}" -u AWS --password-stdin >/dev/null

  for entry in ${MULTIARCH_OVERRIDES}; do
    dest_ref="${registry_prefixed}/${entry%%=*}"
    upstream="${entry#*=}"
    archs="$(crane manifest "${dest_ref}" 2>/dev/null \
      | python3 -c 'import sys,json; m=json.load(sys.stdin); print("\n".join((x.get("platform") or {}).get("architecture","") for x in m.get("manifests",[])))' 2>/dev/null || true)"
    if [[ -z "${archs}" ]]; then
      archs="$(crane config "${dest_ref}" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("architecture",""))' 2>/dev/null || true)"
    fi
    if printf '%s\n' "${archs}" | grep -qx arm64; then
      log "Multi-arch OK: ${dest_ref} already includes arm64."
      continue
    fi
    log "Multi-arch fix: ${dest_ref} lacks arm64 (has: $(printf '%s' "${archs}" | tr '\n' ' ')); copying from ${upstream}..."
    crane copy "${upstream}" "${dest_ref}"
  done
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

  # Prefer the in-workspace chart (as the artifact chart does) so local chart changes apply at once, e.g. the
  # straiker-clickhouse node pool. A pinned --chart-version, or a bundle without charts/, uses the published chart.
  local infra_chart_ref="${HELM_REPO_NAME}/${INFRA_CHART_NAME}"
  local local_infra_chart="${REPO_ROOT}/charts/${INFRA_CHART_NAME}"
  if [[ -z "${CHART_VERSION}" && -d "${local_infra_chart}" ]]; then
    helm dependency build "${local_infra_chart}" >/dev/null
    infra_chart_ref="${local_infra_chart}"
    log "Using local chart at '${infra_chart_ref}'."
  fi

  local cmd=(
    helm upgrade --install "${INFRA_RELEASE}" "${infra_chart_ref}"
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
  if [[ -n "$(get_metadata "gpu_time_slicing_replicas")" ]]; then # test profile: keep the shared-GPU setting across re-runs
    cmd+=(--set "nvidia.devicePlugin.timeSlicing.replicas=$(get_metadata "gpu_time_slicing_replicas")")
  fi

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
  # --data-layer: Aurora replaces the in-cluster postgres, ElastiCache replaces valkey, and
  # EFS backs the model cache. postgres/valkey are nulled so their templates don't render.
  # The postgres storage class is skipped in that case: setting any postgres.* key would
  # re-create the map and render the pod again.
  local resolved_storage_class
  resolved_storage_class="$(get_metadata "resolved_storage_class")"
  if [[ "${DATA_LAYER}" == "true" ]]; then
    local efs_fs_id
    efs_fs_id="$(get_metadata "efs_file_system_id")"
    if [[ -z "${efs_fs_id}" ]]; then
      mark_phase_blocked "No EFS file system in state. Run phase 'aws-data' first."
      return
    fi
    log "--data-layer: in-cluster postgres/valkey disabled; model cache on EFS (${efs_fs_id})."
    cmd+=(
      --set "postgres=null"
      --set "valkey=null"
      --set "efs.enabled=true"
      --set-string "efs.fileSystemId=${efs_fs_id}"
      --set "efs.modelsPvc.enabled=true"
      --set-string "efs.modelsPvc.name=models-filestore-pvc"
      --set-string "efs.modelsPvc.size=1Ti"
    )
    # Managed OpenSearch (Amazon OpenSearch Service) replaces the bundled pod when the data layer created one.
    local os_endpoint os_secret
    os_endpoint="$(get_metadata "opensearch_endpoint")"
    os_secret="$(get_metadata "opensearch_secret_name")"
    if [[ -n "${os_endpoint}" && -n "${os_secret}" ]]; then
      ensure_opensearch_credentials_secret "${os_secret}" || return
      cmd+=(
        --set "tags.opensearch=false"
        --set-string "opensearchExternal.url=https://${os_endpoint}"
        --set-string "opensearchExternal.credentialsSecret=opensearch-credentials"
      )
    fi
  elif [[ -n "${resolved_storage_class}" ]]; then
    cmd+=(--set "postgres.storage.storageClassName=${resolved_storage_class}")
  fi

  # Product -> NodePool mapping: Ascend uses karpenter.iris. karpenter.argus
  # is NOT gated by product selection — straiker-defend is always installed
  # (see phase_straiker_defend), since Ascend's own iris depends on Argus's
  # /api/v1/detect directly, regardless of whether 'defend' was selected.
  # Both are non-null (enabled) by default in the chart's own values.yaml, so
  # an unselected product must be explicitly nulled to skip provisioning its
  # NodePool. Shared system services (opensearch/postgres/redis) aren't
  # gated by product selection at all.
  if [[ ",${PRODUCTS_OPT}," != *",ascend,"* ]]; then
    cmd+=(--set "karpenter.iris=null")
  fi

  # GPU pool (EKS): the customer "p4d" (packed) fleet is pinned to one EC2 type only — p4d.24xlarge by default, or
  # --gpu-instance-type's choice — capped at --gpu-max-nodes, and never expired by age (replacing a node restarts
  # every model server on it and has to win scarce capacity back, worse the fewer, bigger nodes the fleet has).
  # per-model keeps the chart's g4dn/g5/g6/g6e pool. A capacity reservation applies to either.
  if [[ "${CLOUD_PROVIDER}" != "gke" ]]; then
    if [[ "$(gpu_fleet)" == "p4d" ]]; then
      local packed_itype
      packed_itype="$(gpu_instance_type)"
      gpu_instance_spec "${packed_itype}" || { mark_phase_blocked "Unknown --gpu-instance-type '${packed_itype}'."; return; }
      local packed_types packed_families="" t
      packed_types="$(gpu_instance_types)"
      for t in ${packed_types//,/ }; do
        [[ ",${packed_families}," == *",${t%%.*},"* ]] || packed_families+="${packed_families:+,}${t%%.*}"
      done
      cmd+=(
        --set "eks.gpu.instanceFamilies={${packed_families}}"
        --set "eks.gpu.instanceTypes={${packed_types}}"
        --set-string "karpenter.gpu.nodePool.limits.nvidia\\.com/gpu=$(( $(get_metadata "gpu_max_nodes") * GPU_SPEC_GPUS ))"
        --set-string "karpenter.gpu.nodePool.expireAfter=Never"
      )
    fi
    local cr cr_i=0
    for cr in $(printf '%s' "$(get_metadata "gpu_capacity_reservation")" | tr ',' ' '); do
      cmd+=(--set-string "eks.gpu.nodeClass.capacityReservationSelectorTerms[${cr_i}].id=${cr}")
      cr_i=$((cr_i + 1))
    done
  fi

  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  # Karpenter caches the instance types of a node class when it first sees it; a node class created in the same
  # moment as its pool can be cached empty ("nodepool requirements filtered out all instance types") and nothing
  # launches until the controller restarts. So when this upgrade creates node pools, restart the controller.
  local pools_before=""
  if [[ "${CLOUD_PROVIDER}" != "gke" ]]; then
    pools_before="$(kubectl get nodepools.karpenter.sh -o name 2>/dev/null | sort || true)"
  fi
  "${cmd[@]}"
  if [[ "${CLOUD_PROVIDER}" != "gke" ]]; then
    local pools_after
    pools_after="$(kubectl get nodepools.karpenter.sh -o name 2>/dev/null | sort || true)"
    if [[ -n "${pools_after}" && "${pools_after}" != "${pools_before}" ]]; then
      log "New Karpenter node pool(s) created; restarting the Karpenter controller so it picks up their instance types."
      kubectl rollout restart deployment/karpenter -n "${KARPENTER_NAMESPACE:-karpenter}" >/dev/null 2>&1 || true
      kubectl rollout status deployment/karpenter -n "${KARPENTER_NAMESPACE:-karpenter}" --timeout=180s >/dev/null 2>&1 || true
    fi
  fi
}

# Ensures SHARED_SECRETS_NAME exists with every key this installer expects,
# backfilling any that are missing rather than skipping entirely once the
# Secret exists — a key added to this list after a cluster's Secret was
# first created would otherwise stay permanently missing there. Never
# rotates a key that's already set (that would break consumers that already
# picked up the old value); rotating one is a manual `kubectl patch secret`
# followed by restarting the affected workloads.
#
# INTERNAL_API_KEY / SYS__FOUNDATION_API_KEY share one underlying value:
# the frontend strips a "Bearer " prefix before comparing, while argus
# sends it verbatim as the whole header — so the same value is stored
# twice, once bare and once pre-prefixed. VLLM_API_KEY / SYS__INFERENCE_API_KEY
# share their value with no prefix games.
phase_shared_secrets() {
  require_command kubectl
  require_command openssl
  require_command htpasswd

  if ! kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    ensure_k8s_ready_for_charts || return
    kubectl create secret generic "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" >/dev/null
  else
    ensure_k8s_ready_for_charts || return
  fi

  # hex, not base64 — these end up in HTTP Authorization headers verbatim,
  # and hex has no +/= characters to worry about there or in shell
  # interpolation.
  if ! secret_key_exists "INTERNAL_API_KEY"; then
    local internal_key
    internal_key="$(openssl rand -hex 32)"
    patch_shared_secret "INTERNAL_API_KEY" "${internal_key}"
    patch_shared_secret "SYS__FOUNDATION_API_KEY" "Bearer ${internal_key}"
  fi
  if ! secret_key_exists "VLLM_API_KEY"; then
    local inference_key
    inference_key="$(openssl rand -hex 32)"
    patch_shared_secret "VLLM_API_KEY" "${inference_key}"
    patch_shared_secret "SYS__INFERENCE_API_KEY" "${inference_key}"
  fi
  if ! secret_key_exists "IRIS_ADMIN_API_KEY"; then
    patch_shared_secret "IRIS_ADMIN_API_KEY" "$(openssl rand -hex 32)"
  fi

  # Straiker-core's dex bootstrap admin login (see straiker-frontend's
  # dex.staticAdminPasswordHash) — a random password generated once per
  # install, instead of the same hardcoded hash every onprem install used
  # to ship. Plaintext is only ever stored here (retrieve with `kubectl get
  # secret ... -o jsonpath` — see show_bootstrap_admin_reminder); only the
  # bcrypt hash is passed to helm in phase_straiker_core.
  if ! secret_key_exists "BOOTSTRAP_ADMIN_PASSWORD"; then
    local bootstrap_password
    bootstrap_password="$(openssl rand -base64 24)"
    patch_shared_secret "BOOTSTRAP_ADMIN_PASSWORD" "${bootstrap_password}"
    patch_shared_secret "BOOTSTRAP_ADMIN_PASSWORD_HASH" "$(bcrypt_hash "${bootstrap_password}")"
  fi
  # --data-layer: Secrets Manager "<cluster>/platform/shared" is the source of truth. The keys generated
  # above (or already live) are copied there once, then synced back hourly; keys added by other phases
  # (provider API keys, ...) are left alone (creationPolicy Merge).
  if [[ "${DATA_LAYER}" == "true" ]]; then
    ensure_synced_secret straiker-secrets-sync "${CLUSTER_NAME}/platform/shared" "${SHARED_SECRETS_NAME}" "%s" \
      "${SHARED_SECRET_PROPS}" "${SHARED_SECRETS_NAME}" Merge || return
  fi
  log "Secret '${SHARED_SECRETS_NAME}' has all expected service-to-service credentials."
}

# ClickHouse as a pod (opt-in via --data-layer). Image from the customer's ECR mirror.
# True when ClickHouse runs as more than one replica (chart straiker-clickhouse: replicas + Keeper). Then grid's
# migrations and ch-sync's CDC tables must be created with Replicated* engines.
clickhouse_replicated() {
  local n
  n="$(kubectl get statefulset clickhouse -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  if [[ "${n:-1}" =~ ^[0-9]+$ && "${n:-1}" -gt 1 ]]; then echo true; else echo false; fi
}

# Adds a random password to <cluster>/clickhouse/credentials for every user in CLICKHOUSE_PASSWORD_USERS that has none. Existing
# passwords are never changed. A secret that does not exist yet is left to aws-data (Terraform creates it with all the keys).
ensure_clickhouse_secret_keys() {
  local name="${CLUSTER_NAME}/clickhouse/credentials" current merged
  current="$(aws secretsmanager get-secret-value --secret-id "${name}" --region "${AWS_REGION}" --query SecretString --output text 2>/dev/null || true)"
  [[ -n "${current}" ]] || return 0
  merged="$(CURRENT="${current}" USERS="${CLICKHOUSE_PASSWORD_USERS}" python3 - <<'PY'
import json, os, secrets, string
current = json.loads(os.environ["CURRENT"])
alphabet = string.ascii_letters + string.digits
added = [u for u in os.environ["USERS"].split() if not current.get(u)]
for u in added:
    current[u] = "".join(secrets.choice(alphabet) for _ in range(32))
print(json.dumps(current) if added else "SAME")
PY
)"
  [[ "${merged}" == "SAME" ]] && return 0
  aws secretsmanager put-secret-value --secret-id "${name}" --region "${AWS_REGION}" --secret-string "${merged}" >/dev/null \
    || { mark_phase_blocked "Could not add the missing ClickHouse user password(s) to ${name}."; return 1; }
  log "Added the missing ClickHouse user password(s) to ${name}."
}

phase_clickhouse() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    log "--data-layer not set — skipping ClickHouse."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  require_command aws
  require_command kubectl
  require_command helm
  ensure_k8s_ready_for_charts || return

  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  if [[ -z "${ecr_registry}" ]]; then
    mark_phase_blocked "No ECR registry in state. Run phase 'aws-artifacts' first."
    return
  fi
  # Terraform sets the secret's contents once and never rewrites them, so a ClickHouse user added after the first install (grid_sync)
  # has no password there. Add the missing ones here (generated, merged, existing values untouched).
  ensure_clickhouse_secret_keys || return
  ensure_clickhouse_passwords_secret || return
  helm upgrade --install straiker-clickhouse "${REPO_ROOT}/charts/straiker-clickhouse" \
    --namespace "${INFRA_NAMESPACE}" --wait --timeout 15m \
    --set-string image.repository="$(docker_registry_with_prefix "${ecr_registry}")/clickhouse/clickhouse-server"
}

# Sync a Secrets Manager secret (JSON, one property per name) into the K8s Secret <es_name> with an
# ExternalSecret (K8s key = printf <key_fmt> <property>). On an install that predates it (live <seed_secret>
# holding the same keys, no ExternalSecret yet) the live values are first copied into Secrets Manager where
# they differ, so nothing rotates. Marks the phase blocked on failure.
#   $1 es_name  $2 secrets-manager id  $3 seed_secret  $4 key_fmt  $5 properties (space separated)
#   $6 target Secret (default es_name)  $7 creationPolicy (default Owner; Merge adds the keys to an existing
#      Secret and leaves its other keys alone)
ensure_synced_secret() {
  local es_name="$1" sm_id="$2" seed_secret="$3" key_fmt="$4" props="$5" target="${6:-$1}" policy="${7:-Owner}"
  require_command aws
  require_command python3
  if ! kubectl get clustersecretstore "${ESO_STORE_NAME}" >/dev/null 2>&1; then
    mark_phase_blocked "ClusterSecretStore '${ESO_STORE_NAME}' not found. Run phase 'external-secrets' first."
    return 1
  fi
  if ! aws secretsmanager describe-secret --secret-id "${sm_id}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    mark_phase_blocked "Secrets Manager secret '${sm_id}' not found. Re-run phase 'aws-data' (--rerun-phase)."
    return 1
  fi

  if ! kubectl get externalsecret "${es_name}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1 \
     && kubectl get secret "${seed_secret}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    local live_json merged seeded tmp
    live_json="$(kubectl get secret "${seed_secret}" -n "${INFRA_NAMESPACE}" -o json)"
    merged="$(aws secretsmanager get-secret-value --secret-id "${sm_id}" --region "${AWS_REGION}" \
        --query SecretString --output text \
      | LIVE="${live_json}" PROPS="${props}" KEY_FMT="${key_fmt}" python3 -c '
import base64, json, os, sys
sm = json.loads(sys.stdin.read())
live = json.loads(os.environ["LIVE"]).get("data", {})
seeded = []
for p in os.environ["PROPS"].split():
    k = os.environ["KEY_FMT"] % p
    if k in live:
        v = base64.b64decode(live[k]).decode()
        if sm.get(p) != v:
            sm[p] = v
            seeded.append(p)
print(json.dumps({"seeded": seeded, "secret": sm}))')"
    seeded="$(printf '%s' "${merged}" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["seeded"]))')"
    if [[ -n "${seeded}" ]]; then
      tmp="$(mktemp)"
      printf '%s' "${merged}" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.load(sys.stdin)["secret"]))' > "${tmp}"
      aws secretsmanager put-secret-value --secret-id "${sm_id}" --region "${AWS_REGION}" \
        --secret-string "file://${tmp}" >/dev/null
      rm -f "${tmp}"
      log "Seeded Secrets Manager '${sm_id}' with the live values of: ${seeded}"
    fi
  fi

  local p entries=""
  for p in ${props}; do
    entries+="    - {secretKey: $(printf "${key_fmt}" "${p}"), remoteRef: {key: ${sm_id}, property: ${p}}}"$'\n'
  done
  kubectl apply -n "${INFRA_NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${es_name}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: ${ESO_STORE_NAME}, kind: ClusterSecretStore}
  target: {name: ${target}, creationPolicy: ${policy}}
  data:
${entries}
EOF
  if ! kubectl wait externalsecret/"${es_name}" -n "${INFRA_NAMESPACE}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    mark_phase_blocked "ExternalSecret ${es_name} is not Ready. Check: kubectl describe externalsecret ${es_name} -n ${INFRA_NAMESPACE}"
    return 1
  fi
}

# Aurora role passwords and the platform-internal S2S key (charts/straiker-data reads both).
ensure_db_passwords_secret() {
  ensure_synced_secret straiker-db-passwords "${CLUSTER_NAME}/db/passwords" straiker-db-dsn "PASSWORD_%s" "${DB_PASSWORD_ROLES}" || return 1
  ensure_synced_secret platform-keys "${CLUSTER_NAME}/platform/keys" platform-secret "%s" "PLATFORM_INTERNAL_S2S_API_KEY"
}

# ClickHouse user passwords (chart straiker-clickhouse reads them).
ensure_clickhouse_passwords_secret() {
  ensure_synced_secret clickhouse-passwords "${CLUSTER_NAME}/clickhouse/credentials" clickhouse-credentials "%s_password" "${CLICKHOUSE_PASSWORD_USERS}"
}

# creationPolicy for an ExternalSecret that takes over K8s Secret <name>: keep an existing ExternalSecret's
# policy; Merge for a pre-existing, unowned (Helm-created) Secret, so ESO adopts it without deleting it; else Owner.
eso_creation_policy() {
  local name="$1" policy
  policy="$(kubectl get externalsecret "${name}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.target.creationPolicy}' 2>/dev/null || true)"
  if [[ -n "${policy}" ]]; then
    printf '%s' "${policy}"
  elif kubectl get secret "${name}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1 \
       && [[ -z "$(kubectl get secret "${name}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)" ]]; then
    printf 'Merge'
  else
    printf 'Owner'
  fi
}

# Dry run before straiker-data's ExternalSecrets take over straiker-db-dsn / platform-secret: render the same
# ExternalSecrets against "<name>-preview" targets, wait for them, and compare every key with the live Secrets.
# Any differing value blocks the phase (a template mistake would otherwise overwrite working Secrets). Values
# are never printed. Skipped on a fresh install (no live Secrets) and once the ExternalSecrets exist.
# Args: the helm --set flags of the straiker-data install.
eso_preview_diff() {
  local live
  for live in straiker-db-dsn platform-secret; do
    if kubectl get externalsecret "${live}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then return 0; fi
  done
  for live in straiker-db-dsn platform-secret; do
    if ! kubectl get secret "${live}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then return 0; fi
  done

  log "Previewing the ExternalSecret-built straiker-db-dsn / platform-secret against the live Secrets..."
  if ! helm template straiker-data "${REPO_ROOT}/charts/straiker-data" --namespace "${INFRA_NAMESPACE}" "$@" \
        --set-string eso.previewSuffix=-preview --show-only templates/eso-secrets.yaml \
      | kubectl apply -n "${INFRA_NAMESPACE}" -f - >/dev/null; then
    mark_phase_blocked "Could not render/apply the preview ExternalSecrets for straiker-data."
    return 1
  fi

  local rc=0 out
  for live in straiker-db-dsn platform-secret; do
    if ! kubectl wait externalsecret/"${live}-preview" -n "${INFRA_NAMESPACE}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
      log "FAIL  preview ExternalSecret ${live}-preview is not Ready (kubectl describe externalsecret ${live}-preview -n ${INFRA_NAMESPACE})."
      rc=1
      continue
    fi
    out="$(LIVE="$(kubectl get secret "${live}" -n "${INFRA_NAMESPACE}" -o json)" \
           PREV="$(kubectl get secret "${live}-preview" -n "${INFRA_NAMESPACE}" -o json)" python3 -c '
import json, os
live = json.loads(os.environ["LIVE"]).get("data", {})
prev = json.loads(os.environ["PREV"]).get("data", {})
diff = sorted(k for k in prev if k in live and prev[k] != live[k])
new = sorted(k for k in prev if k not in live)
gone = sorted(k for k in live if k not in prev)
print("DIFF " + " ".join(diff))
print("NEW " + " ".join(new))
print("ONLY-LIVE " + " ".join(gone))')"
    if [[ "$(printf '%s\n' "${out}" | sed -n 's/^DIFF *//p')" != "" ]]; then
      log "FAIL  ${live}: values would change for: $(printf '%s\n' "${out}" | sed -n 's/^DIFF *//p')"
      rc=1
    else
      log "PASS  ${live}: every key matches the live Secret (new keys: $(printf '%s\n' "${out}" | sed -n 's/^NEW *//p'); only in live: $(printf '%s\n' "${out}" | sed -n 's/^ONLY-LIVE *//p'))"
    fi
  done

  for live in straiker-db-dsn platform-secret; do
    kubectl delete externalsecret "${live}-preview" -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl delete secret "${live}-preview" -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  done
  if [[ "${rc}" -ne 0 ]]; then
    mark_phase_blocked "The ExternalSecret-built Secrets would differ from the live ones (see FAIL lines above); nothing was changed. Send the output before re-running."
    return 1
  fi
}

# Bootstraps the AWS data tier from inside the cluster (opt-in via --data-layer):
# Aurora databases/roles + DSN Secret and MSK topics, via chart straiker-data.
phase_data_bootstrap() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    log "--data-layer not set — skipping data bootstrap."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  require_command aws
  require_command kubectl
  require_command helm
  require_command python3
  ensure_k8s_ready_for_charts || return

  local aurora_host aurora_port master_arn msk_arn
  aurora_host="$(get_metadata "aurora_endpoint")"
  aurora_port="$(get_metadata "aurora_port")"
  master_arn="$(get_metadata "aurora_master_secret_arn")"
  msk_arn="$(get_metadata "msk_cluster_arn")"
  if [[ -z "${aurora_host}" || -z "${master_arn}" || -z "${msk_arn}" ]]; then
    mark_phase_blocked "Data tier metadata missing (aurora/msk). Run phase 'aws-data' first."
    return
  fi

  local brokers
  brokers="$(aws kafka get-bootstrap-brokers --cluster-arn "${msk_arn}" --region "${AWS_REGION}" \
    --query 'BootstrapBrokerStringSaslIam' --output text 2>/dev/null || true)"
  if [[ -z "${brokers}" || "${brokers}" == "None" ]]; then
    mark_phase_blocked "Could not get SASL/IAM bootstrap brokers for ${msk_arn}."
    return
  fi

  # Per Aurora cluster: RDS-managed master login -> K8s Secret read by that cluster's bootstrap
  # Job, and its host/port -> chart values. "platform" uses the original aurora_endpoint /
  # aurora_master_secret_arn metadata and Secret name; the others (aws-data records them in
  # aurora_other_clusters) use aurora_<key>_endpoint / _master_secret_arn and
  # Secret straiker-aurora-admin-<key>. A cluster missing from state is skipped: the chart then
  # places its databases on "platform" (single-cluster installs keep working).
  local secret_json user pass ck ck_host ck_arn ck_secret
  local -a aurora_sets=()
  for ck in platform $(get_metadata "aurora_other_clusters"); do
    if [[ "${ck}" == "platform" ]]; then
      ck_host="${aurora_host}"; ck_arn="${master_arn}"; ck_secret="straiker-aurora-admin"
    else
      ck_host="$(get_metadata "aurora_${ck}_endpoint")"; ck_arn="$(get_metadata "aurora_${ck}_master_secret_arn")"
      ck_secret="straiker-aurora-admin-${ck}"
    fi
    if [[ -z "${ck_host}" || -z "${ck_arn}" ]]; then
      log "WARN  Aurora cluster '${ck}' has no endpoint/secret in install state; its databases fall back to 'platform'. Re-run phase 'aws-data'."
      continue
    fi
    ensure_aurora_admin_secret "${ck_secret}" "${ck_arn}" || return
    aurora_sets+=(
      --set-string "aurora.clusters.${ck}.host=${ck_host}"
      --set "aurora.clusters.${ck}.port=${aurora_port:-5432}"
      --set-string "aurora.clusters.${ck}.adminSecret=${ck_secret}"
    )
  done

  # api-gateway key bundle (Terraform-generated): foundation/registry/argus must share two of its keys.
  local gw_json validate_key s2s_key
  gw_json="$(aws secretsmanager get-secret-value --secret-id "${CLUSTER_NAME}/platform/api-gateway" --region "${AWS_REGION}" \
    --query SecretString --output text 2>/dev/null || true)"
  if [[ -n "${gw_json}" ]]; then
    validate_key="$(printf '%s' "${gw_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("PLATFORM_VALIDATE_KEY",""))')"
    s2s_key="$(printf '%s' "${gw_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("SYS__ARGUS_INTERNAL_S2S_KEY",""))')"
    # argus reads the same key from the shared secret
    if kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1 && [[ -n "${s2s_key}" ]]; then
      patch_shared_secret "SYS__ARGUS_INTERNAL_S2S_KEY" "${s2s_key}"
    fi
  fi

  ensure_db_passwords_secret || return

  local -a data_sets=(
    --set-string "platform.validateKey=${validate_key:-}"
    --set-string "platform.gatewayS2SKey=${s2s_key:-}"
    --set "aws.region=${AWS_REGION}"
    --set-string "msk.bootstrapBrokers=${brokers//,/\\,}"
  )
  data_sets+=(${aurora_sets[@]+"${aurora_sets[@]}"})

  # straiker-db-dsn and platform-secret are ExternalSecrets reading Secrets Manager (like SaaS). ClickHouse
  # host/port are not secret: passed as values from the live clickhouse-credentials Secret.
  data_sets+=(--set "eso.enabled=true" --set-string "eso.smPrefix=${CLUSTER_NAME}")
  if kubectl get secret clickhouse-credentials -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    local chk
    for chk in host ddlHost nativePort; do
      data_sets+=(--set-string "platform.clickhouse.${chk}=$(kubectl get secret clickhouse-credentials -n "${INFRA_NAMESPACE}" -o jsonpath="{.data.${chk}}" | base64 -d)")
    done
  fi
  data_sets+=(
    --set-string "eso.dsnCreationPolicy=$(eso_creation_policy straiker-db-dsn)"
    --set-string "eso.platformCreationPolicy=$(eso_creation_policy platform-secret)"
  )

  eso_preview_diff "${data_sets[@]}" || return

  helm upgrade --install straiker-data "${REPO_ROOT}/charts/straiker-data" \
    --namespace "${INFRA_NAMESPACE}" --wait --timeout 15m \
    "${data_sets[@]}" || return

  local es
  for es in straiker-db-dsn platform-secret; do
    if ! kubectl wait externalsecret/"${es}" -n "${INFRA_NAMESPACE}" --for=condition=Ready --timeout=180s >/dev/null 2>&1; then
      mark_phase_blocked "ExternalSecret ${es} is not Ready. Check: kubectl describe externalsecret ${es} -n ${INFRA_NAMESPACE}"
      return
    fi
  done
}

# Registry Postgres -> ClickHouse dimension sync (opt-in via --data-layer).
phase_ch_sync() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    log "--data-layer not set — skipping ClickHouse sync."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  require_command kubectl
  require_command helm
  ensure_k8s_ready_for_charts || return

  local ecr_registry aurora_host aurora_port
  ecr_registry="$(get_metadata "ecr_registry")"
  aurora_host="$(get_metadata "aurora_endpoint")"
  aurora_port="$(get_metadata "aurora_port")"
  if [[ -z "${ecr_registry}" || -z "${aurora_host}" ]]; then
    mark_phase_blocked "Missing ECR/Aurora state. Run phases 'aws-artifacts' and 'aws-data' first."
    return
  fi
  if ! kubectl get secret clickhouse-credentials -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    mark_phase_blocked "Secret 'clickhouse-credentials' missing. Run phase 'clickhouse' first."
    return
  fi
  if ! kubectl get secret straiker-db-dsn -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.PASSWORD_grid_cdc}' 2>/dev/null | grep -q .; then
    mark_phase_blocked "No grid_cdc password in 'straiker-db-dsn'. Run phase 'data-bootstrap' first."
    return
  fi
  # Tables missing in Postgres (registry not installed yet) are skipped each cycle and picked up
  # once registry's migration creates them, so this can run before platform-services.
  helm upgrade --install straiker-ch-sync "${REPO_ROOT}/charts/straiker-ch-sync" \
    --namespace "${INFRA_NAMESPACE}" --wait --timeout 15m \
    --set-string image.repository="$(docker_registry_with_prefix "${ecr_registry}")/clickhouse/clickhouse-server" \
    --set-string postgres.host="${aurora_host}" \
    --set-string postgres.port="${aurora_port:-5432}" \
    --set clickhouse.replicated="$(clickhouse_replicated)"
}

# Kafka -> ClickHouse ingestion (opt-in via --data-layer). Requires grid's ClickHouse tables.
phase_ingest() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    log "--data-layer not set — skipping ingestion."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  require_command kubectl
  require_command helm
  ensure_k8s_ready_for_charts || return

  local ecr_registry msk_arn brokers
  ecr_registry="$(get_metadata "ecr_registry")"
  msk_arn="$(get_metadata "msk_cluster_arn")"
  if [[ -z "${ecr_registry}" || -z "${msk_arn}" ]]; then
    mark_phase_blocked "Missing ECR/MSK state. Run phases 'aws-artifacts' and 'aws-data' first."
    return
  fi
  brokers="$(aws kafka get-bootstrap-brokers --cluster-arn "${msk_arn}" --region "${AWS_REGION}" \
    --query 'BootstrapBrokerStringSaslIam' --output text 2>/dev/null || true)"
  if [[ -z "${brokers}" || "${brokers}" == "None" ]]; then
    mark_phase_blocked "Could not get SASL/IAM bootstrap brokers for ${msk_arn}."
    return
  fi
  # Inserting before grid's migration has created the tables would send every message to the DLQ.
  local ch_pw
  ch_pw="$(kubectl get secret clickhouse-credentials -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d || true)"
  if [[ -z "${ch_pw}" ]] || ! kubectl exec -n "${INFRA_NAMESPACE}" statefulset/clickhouse -- \
      clickhouse-client --user admin --password "${ch_pw}" --query 'EXISTS TABLE grid.raw_event' 2>/dev/null | grep -qx 1; then
    mark_phase_blocked "grid.raw_event does not exist yet. Install grid (PLATFORM_SERVICES must include grid, so its migration runs) first."
    return
  fi
  helm upgrade --install straiker-ingest "${REPO_ROOT}/charts/straiker-ingest" \
    --namespace "${INFRA_NAMESPACE}" --wait --timeout 10m \
    --set-string image.repository="$(docker_registry_with_prefix "${ecr_registry}")/redpandadata/connect" \
    --set-string bus.brokers="${brokers//,/\\,}" \
    --set-string bus.sasl.region="${AWS_REGION}"
}

# api-gateway. FULL mode when the data tier provides the DynamoDB environment table (state key
# dynamodb_environment_table): environments in DynamoDB (apiKey-index), s2s keys from Secrets Manager
# <cluster>/platform/api-gateway, integration-key edge for /api/v3/detect. Otherwise READ-ONLY mode (static
# environment ConfigMap, no AWS services). OAuth and PAT stay in-memory in both (Cognito is not part of the
# on-prem stack yet). Generated once and kept in K8s Secrets: OAuth signing key + client ('api-gateway-oauth')
# and the first environment's API key ('api-gateway-env').
# Gateway exposure: flag > remembered > public. public needs a certificate: the gateway is never put on the
# internet without TLS.
remember_gateway_settings() {
  local mode="${GATEWAY_EXPOSURE:-$(get_metadata "gateway_exposure")}"
  mode="${mode:-public}"
  case "${mode}" in internal | public | none) ;; *)
    mark_phase_blocked "--gateway-exposure must be internal, public or none (got '${mode}')."
    return 1
    ;;
  esac
  local cert="${GATEWAY_CERT_ARN:-$(get_metadata "gateway_cert_arn")}"
  local domain="${GATEWAY_DOMAIN:-$(get_metadata "gateway_domain")}"
  local zone="${GATEWAY_ZONE_ID:-$(get_metadata "gateway_zone_id")}"
  local cidrs="${GATEWAY_ALLOWED_CIDRS:-$(get_metadata "gateway_allowed_cidrs")}"
  local source
  source="$(get_metadata "gateway_cert_source")"
  [[ -n "${GATEWAY_CERT_ARN}" ]] && source="own"
  if [[ -n "${domain}" && ! "${domain}" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    mark_phase_blocked "--gateway-domain must be a lower-case host name such as api.customer.com (got '${domain}')."
    return 1
  fi
  if [[ "${mode}" == "public" ]]; then
    if [[ -n "${cert}" && ! "${cert}" =~ ^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+$ ]]; then
      mark_phase_blocked "--gateway-cert-arn must be an ACM certificate ARN (got '${cert}')."
      return 1
    fi
    if [[ -n "${cert}" && "${cert}" != *":acm:${AWS_REGION}:"* ]]; then
      mark_phase_blocked "The gateway certificate must be in the cluster's region (${AWS_REGION}): a load balancer cannot use a certificate from another region."
      return 1
    fi
    # Edge type xalb: the gateway rides the same ALB; its name defaults to api.<custom domain>.
    if [[ -z "${cert}" && -z "${domain}" && "${EDGE_TYPE}" == "xalb" && -n "$(get_metadata "custom_domain")" ]]; then
      domain="$(custom_domain_hostname api)"
      log "api-gateway name defaults to ${domain} (edge type xalb; pass --gateway-domain for another name)."
    fi
    if [[ -z "${cert}" && -z "${domain}" ]]; then
      mark_phase_blocked "The api-gateway is internet-facing by default and needs TLS. Pass --gateway-domain <name> (the installer then issues the certificate: fully automatic with a Route53 zone for it in this account), or --gateway-cert-arn <your ACM certificate>, or choose a private gateway with --gateway-exposure internal. It is never exposed to the internet without TLS."
      return 1
    fi
    if [[ -z "${cidrs}" ]]; then
      log "WARNING: --gateway-exposure public without --gateway-allowed-cidrs: the gateway accepts connections from any address."
    fi
  fi
  set_metadata "gateway_exposure" "${mode}"
  set_metadata "gateway_cert_arn" "${cert}"
  set_metadata "gateway_cert_source" "${source}"
  set_metadata "gateway_domain" "${domain}"
  set_metadata "gateway_zone_id" "${zone}"
  set_metadata "gateway_allowed_cidrs" "${cidrs}"
}

# The console's platform-API views (Defend overview: identities, agents, models, tools, findings; Controls) call the
# api-gateway with the console's own signed session. api-gateway accepts that session from GATEWAY_CONSOLE_SESSION_FROM on
# (OnpremSessionTokenVerifier, keyed by the console's SESSION_SIGNING_KEY); older images reject it (sign-in ends in 401).
# Needs --data-layer: the shared key lives in Secrets Manager (<cluster>/frontend/auth), synced to both pods.
GATEWAY_CONSOLE_SESSION_FROM="2.3.13"
gateway_accepts_console_session() {
  [[ "${DATA_LAYER}" == "true" ]] || return 1
  local tag
  tag="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${REPO_ROOT}/charts/platform-api-gateway/Chart.yaml")"
  TAG="${tag}" MIN="${GATEWAY_CONSOLE_SESSION_FROM}" python3 -c '
import os, re, sys
num = lambda v: tuple(int(x) for x in re.findall(r"\d+", v.split("-")[0])[:3])
sys.exit(0 if num(os.environ["TAG"].lstrip("v")) >= num(os.environ["MIN"]) else 1)'
}

# True when the public api-gateway is served by the edge ALB (edge type xalb) instead of its own NLB: its Service is
# then ClusterIP and charts/straiker-edge adds the gateway's Ingress to the xalb IngressGroup (same ALB, same WAF).
gateway_via_alb() {
  [[ "${EDGE_TYPE}" == "xalb" && "$(get_metadata "gateway_exposure")" == "public" ]]
}

install_api_gateway() {
  local ecr_registry=$1 chart="${REPO_ROOT}/charts/platform-api-gateway" tag tmp table
  require_command openssl
  remember_gateway_settings || return 1
  gateway_cert_require_issued || return 1
  tag="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${chart}/Chart.yaml")"
  table="$(get_metadata "dynamodb_environment_table")"

  if ! kubectl get secret api-gateway-oauth -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${tmp}/signing-key.pem" 2>/dev/null
    kubectl create secret generic api-gateway-oauth -n "${INFRA_NAMESPACE}" \
      --from-file=signing-key.pem="${tmp}/signing-key.pem" \
      --from-literal=client-id=onprem-client \
      --from-literal=client-secret="$(openssl rand -hex 32)" >/dev/null
    rm -rf "${tmp}"
  fi
  if ! kubectl get secret api-gateway-env -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    kubectl create secret generic api-gateway-env -n "${INFRA_NAMESPACE}" \
      --from-literal=env-key="$(openssl rand -hex 24)" >/dev/null
  fi
  local env_key
  env_key="$(kubectl get secret api-gateway-env -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.env-key}' | base64 -d)"

  local -a mode_args=()
  # The console's signed session as a user login (see gateway_accepts_console_session): same Secret as the console.
  if gateway_accepts_console_session; then
    ensure_synced_secret frontend-session-source "${CLUSTER_NAME}/frontend/auth" straiker-frontend-auth "%s" \
      "SESSION_SIGNING_KEY" || return 1
    mode_args+=(--set-string "straiker.apiGateway.onpremSession.signingKeySecret.name=frontend-session-source")
  fi
  if [[ -n "${table}" ]]; then
    require_command aws
    log "api-gateway: full mode (DynamoDB table ${table})."
    # First environment (straikerId 1 / environmentId 1), created only if absent.
    aws dynamodb put-item --table-name "${table}" --region "${AWS_REGION}" \
      --condition-expression 'attribute_not_exists(pk)' \
      --item "{\"pk\":{\"S\":\"ENV#1\"},\"sk\":{\"S\":\"META\"},\"apiKey\":{\"S\":\"${env_key}\"},\"environmentId\":{\"N\":\"1\"},\"straikerId\":{\"N\":\"1\"}}" \
      >/dev/null 2>&1 || true
    mode_args+=(
      --set straiker.readonly.enabled=false
      --set-string "straiker.apiGateway.secretManager.secretName=${CLUSTER_NAME}/platform/api-gateway"
      --set-string "straiker.apiGateway.secretManager.region=${AWS_REGION}"
      --set-string "straiker.apiGateway.dynamodb.region=${AWS_REGION}"
      --set-string "straiker.apiGateway.dynamodb.environmentTable=${table}"
      --set-string "straiker.apiGateway.integrationKeys.secretPrefix=${CLUSTER_NAME}/platform/integration/"
      --set-string "straiker.apiGateway.integrationKeys.region=${AWS_REGION}"
    )
  else
    log "api-gateway: read-only mode (no DynamoDB table in state; run with --data-layer for full mode)."
    # Static environment the gateway authenticates agents against (schema: api-gateway
    # deploy/k8s/straiker-readonly-environments.yaml). Created once; edit the ConfigMap to add environments.
    if ! kubectl get configmap straiker-readonly-environments -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
      kubectl create configmap straiker-readonly-environments -n "${INFRA_NAMESPACE}" \
        --from-literal=readonly-config.yaml="environments:
  - straiker-id: \"1\"
    environment-id: \"1\"
    app-id: \"1\"
    env-key: \"${env_key}\"
    controls:
      remote_code_execution: block
      tool_misuse: detect
      resource_exhaustion: detect
      data_exfiltration: block
" >/dev/null
    fi
    mode_args+=(--set straiker.readonly.enabled=true)
  fi

  local key_file client_id client_secret
  key_file="$(mktemp)"
  kubectl get secret api-gateway-oauth -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.signing-key\.pem}' | base64 -d > "${key_file}"
  client_id="$(kubectl get secret api-gateway-oauth -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.client-id}' | base64 -d)"
  client_secret="$(kubectl get secret api-gateway-oauth -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.client-secret}' | base64 -d)"

  # Allowed source CIDRs -> straiker.apiGateway.service.sourceRanges[i] (public only; empty = none).
  local gateway_cidr_args=() cidr_i=0 cidr_item service_exposure
  service_exposure="$(get_metadata "gateway_exposure")"
  gateway_via_alb && service_exposure=none
  if [[ "${service_exposure}" == "public" && -n "$(get_metadata "gateway_allowed_cidrs")" ]]; then
    for cidr_item in $(printf '%s' "$(get_metadata "gateway_allowed_cidrs")" | tr ',' ' '); do
      gateway_cidr_args+=(--set-string "straiker.apiGateway.service.sourceRanges[${cidr_i}]=${cidr_item}")
      cidr_i=$((cidr_i + 1))
    done
  fi
  # Which controller provisions the gateway's load balancer decides which Service annotations take effect.
  local gateway_lbc=false
  kubectl get deploy aws-load-balancer-controller -n kube-system >/dev/null 2>&1 && gateway_lbc=true
  if gateway_via_alb; then
    log "Installing platform service 'api-gateway' (${tag}, public through the edge ALB: phase straiker-edge adds its route and DNS)..."
  else
    log "Installing platform service 'api-gateway' (${tag}, exposure $(get_metadata "gateway_exposure"))..."
  fi
  local -a ha_gw_args=()
  if ha_enabled; then
    ha_gw_args=(--set straiker.apiGateway.replicas=2
      --set 'straiker.apiGateway.topologySpreadConstraints[0].maxSkew=1'
      --set-string 'straiker.apiGateway.topologySpreadConstraints[0].topologyKey=topology.kubernetes.io/zone'
      --set-string 'straiker.apiGateway.topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway'
      --set-string 'straiker.apiGateway.topologySpreadConstraints[0].labelSelector.matchLabels.app\.straiker\.io/app=api-gateway')
  fi
  helm upgrade --install api-gateway "${chart}" \
    --namespace "${INFRA_NAMESPACE}" --wait --timeout 10m \
    -f "${chart}/values-onprem.yaml" \
    --set-string straiker.apiGateway.image.registry="$(docker_registry_with_prefix "${ecr_registry}")/straiker" \
    --set-string straiker.apiGateway.image.version="${tag}" \
    --set-string straiker.apiGateway.service.exposure="${service_exposure}" \
    --set-string straiker.apiGateway.service.awsLoadBalancerController="${gateway_lbc}" \
    --set-string straiker.apiGateway.service.certificateArn="$(get_metadata "gateway_cert_arn")" \
    ${gateway_cidr_args[@]+"${gateway_cidr_args[@]}"} \
    ${ha_gw_args[@]+"${ha_gw_args[@]}"} \
    --set-file straiker.apiGateway.oauth.inmemory.signingKey="${key_file}" \
    --set-string "straiker.apiGateway.oauth.inmemory.clients[0].client-id=${client_id}" \
    --set-string "straiker.apiGateway.oauth.inmemory.clients[0].client-secret=${client_secret}" \
    "${mode_args[@]}"
  local rc=$?
  rm -f "${key_file}"
  [[ ${rc} -eq 0 ]] || return ${rc}
  gateway_via_alb && return 0
  verify_gateway_exposure || return 1
  gateway_dns_ensure
}

# ---- Gateway TLS certificate: issued by the installer when --gateway-domain is given -----------------------------------------------
# Needs (installer identity): acm:RequestCertificate/DescribeCertificate/ListCertificates/ListTagsForCertificate/AddTagsToCertificate,
# route53:ListHostedZones/ChangeResourceRecordSets, elasticloadbalancing:DescribeLoadBalancers.

# "<zone id>" of the public Route53 zone whose name is the longest suffix of the domain (or the --gateway-zone-id override); empty if none.
gateway_find_zone() {
  local domain=$1 override
  override="$(get_metadata "gateway_zone_id")"
  if [[ -n "${override}" ]]; then printf '%s' "${override}"; return 0; fi
  aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone==`false`].[Id,Name]' --output text 2>/dev/null \
    | DOMAIN="${domain}" python3 -c '
import os, sys
d = os.environ["DOMAIN"].rstrip(".") + "."
best = ("", "")
for line in sys.stdin:
    parts = line.split()
    if len(parts) != 2:
        continue
    zid, name = parts
    if (d == name or d.endswith("." + name)) and len(name) > len(best[1]):
        best = (zid.rsplit("/", 1)[-1], name)
print(best[0], end="")
'
}

# ARN of this cluster's certificate for the domain that is still usable (ISSUED or PENDING_VALIDATION); empty if none.
gateway_cert_find() {
  local domain=$1 arn tag
  for arn in $(aws acm list-certificates --region "${AWS_REGION}" --certificate-statuses ISSUED PENDING_VALIDATION \
      --query "CertificateSummaryList[?DomainName=='${domain}'].CertificateArn" --output text 2>/dev/null); do
    tag="$(aws acm list-tags-for-certificate --region "${AWS_REGION}" --certificate-arn "${arn}" \
      --query "Tags[?Key=='straiker:cluster'].Value | [0]" --output text 2>/dev/null)"
    if [[ "${tag}" == "${CLUSTER_NAME}" ]]; then printf '%s' "${arn}"; return 0; fi
  done
}

gateway_cert_status() {
  aws acm describe-certificate --region "${AWS_REGION}" --certificate-arn "$1" --query Certificate.Status --output text 2>/dev/null
}

# "name type value" of the DNS validation record ACM asks for (it appears a few seconds after the request); empty if not yet.
gateway_cert_validation_record() {
  local arn=$1 n rec=""
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    rec="$(aws acm describe-certificate --region "${AWS_REGION}" --certificate-arn "${arn}" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Type,Value]' --output text 2>/dev/null)"
    [[ -n "${rec}" && "${rec}" != "None" && "${rec}" != *"None"* ]] && break
    rec=""
    sleep 5
  done
  printf '%s' "${rec}"
}

# route53_upsert <zone id> <name> <type> <value>
route53_upsert() {
  local batch
  batch="$(NAME="$2" TYPE="$3" VALUE="$4" python3 -c '
import json, os
print(json.dumps({"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {"Name": os.environ["NAME"], "Type": os.environ["TYPE"], "TTL": 300,
      "ResourceRecords": [{"Value": os.environ["VALUE"]}]}}]}))')"
  aws route53 change-resource-record-sets --hosted-zone-id "$1" --change-batch "${batch}" >/dev/null
}

# The manual DNS step (domain not in a Route53 zone of this account) as a sheet for the customer's DNS admin: no secrets, written
# whenever a record becomes known and rewritten as the second one (the gateway name) appears.
gateway_dns_handoff() {
  local domain valid record file
  domain="$(get_metadata "gateway_domain")"
  valid="$(get_metadata "gateway_cert_validation")"
  record="$(get_metadata "gateway_dns_record")"
  [[ -n "${domain}" && -n "${valid}${record}" ]] || return 0
  file="${HOME}/.straiker/gateway-dns-handoff-${CLUSTER_NAME}.md"
  mkdir -p "${HOME}/.straiker"
  {
    echo "# DNS records for the Straiker API gateway: ${domain}"
    echo
    echo "Add these where **${domain}** is hosted (no secrets in this sheet; cluster ${CLUSTER_NAME})."
    echo
    echo "## 1. Certificate validation: add this first"
    if [[ -n "${valid}" ]]; then
      read -r vname vtype vvalue <<<"${valid}"
      echo
      echo "| Name | Type | Value |"
      echo "|---|---|---|"
      echo "| \`${vname}\` | ${vtype} | \`${vvalue}\` |"
      echo
      echo "AWS then issues the TLS certificate, usually within minutes. Keep the record: it renews the certificate automatically."
    else
      echo
      echo "Not published yet; re-run the installer and this sheet is updated."
    fi
    echo
    echo "## 2. The gateway name: add this once the installer prints it"
    echo
    if [[ -n "${record}" ]]; then
      read -r dname dtype dvalue <<<"${record}"
      echo "| Name | Type | Value |"
      echo "|---|---|---|"
      echo "| \`${dname}\` | ${dtype} | \`${dvalue}\` |"
    else
      echo "Created after the gateway's load balancer exists (late in the install). The installer prints it and updates this sheet."
    fi
  } >"${file}"
  log "MANUAL STEP: DNS records for ${domain} are in ${file} (send it to whoever manages that DNS)."
}

# Phase: request the gateway certificate early so DNS validation overlaps with the rest of the install. A Route53 zone in this account:
# the validation record is written here. DNS elsewhere: the record to add is printed now and again when the gateway needs the certificate.
phase_gateway_cert() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  remember_gateway_settings || return
  if [[ "$(get_metadata "gateway_exposure")" != "public" ]]; then
    log "Gateway exposure is '$(get_metadata "gateway_exposure")': no certificate needed."
    set_phase_status "${CURRENT_PHASE}" "skipped" "gateway not internet-facing."
    return
  fi
  require_command aws
  local domain cert zone rec rname rtype rvalue status
  domain="$(get_metadata "gateway_domain")"
  cert="$(get_metadata "gateway_cert_arn")"
  if [[ "$(get_metadata "gateway_cert_source")" == "own" ]]; then
    status="$(gateway_cert_status "${cert}")"
    if [[ "${status}" == "ISSUED" ]]; then
      log "Using your ACM certificate ${cert} (issued)."
    else
      log "WARNING: your ACM certificate ${cert} is '${status:-not readable}', not ISSUED: the gateway's TLS listener will not work until it is."
    fi
    return
  fi

  # Issue (or reuse) the certificate for --gateway-domain.
  if [[ -z "${cert}" ]]; then cert="$(gateway_cert_find "${domain}")"; fi
  if [[ -z "${cert}" ]]; then
    cert="$(aws acm request-certificate --region "${AWS_REGION}" --domain-name "${domain}" --validation-method DNS \
      --tags "Key=straiker:cluster,Value=${CLUSTER_NAME}" "Key=managed_by,Value=straiker-installer" \
      --query CertificateArn --output text)" || { mark_phase_blocked "Could not request an ACM certificate for ${domain}."; return; }
    log "Requested ACM certificate for ${domain}: ${cert}"
  else
    log "Reusing ACM certificate for ${domain}: ${cert}"
  fi
  set_metadata "gateway_cert_arn" "${cert}"
  set_metadata "gateway_cert_source" "issued"

  status="$(gateway_cert_status "${cert}")"
  [[ "${status}" == "ISSUED" ]] && { log "The certificate is already issued."; return; }

  rec="$(gateway_cert_validation_record "${cert}")"
  if [[ -z "${rec}" ]]; then
    log "WARNING: ACM has not published the validation record yet; the gateway step will look again."
    return
  fi
  read -r rname rtype rvalue <<<"${rec}"
  set_metadata "gateway_cert_validation" "${rname} ${rtype} ${rvalue}"
  zone="$(gateway_find_zone "${domain}")"
  if [[ -n "${zone}" ]]; then
    route53_upsert "${zone}" "${rname}" "${rtype}" "${rvalue}" \
      || { mark_phase_blocked "Could not write the validation record to Route53 zone ${zone} (needs route53:ChangeResourceRecordSets)."; return; }
    log "Wrote the DNS validation record to Route53 zone ${zone}; ACM validates it in a few minutes while the install continues."
  else
    log "No public Route53 zone for ${domain} in this account. ADD THIS DNS RECORD where ${domain} is hosted (the install continues; the gateway step waits for it):"
    log "    ${rname}  ${rtype}  ${rvalue}"
    gateway_dns_handoff
  fi
}

# Before the gateway chart: the certificate must be ISSUED. Waits for DNS validation; blocks with the record to add if it does not arrive.
gateway_cert_require_issued() {
  [[ "$(get_metadata "gateway_exposure")" == "public" ]] || return 0
  local cert status n rec waits=60
  cert="$(get_metadata "gateway_cert_arn")"
  [[ -n "${cert}" ]] || { mark_phase_blocked "No gateway certificate: run phase gateway-cert."; return 1; }
  [[ -n "$(gateway_find_zone "$(get_metadata "gateway_domain")")" ]] || waits=20 # a person has to add the record: do not wait as long
  for n in $(seq 1 "${waits}"); do
    status="$(gateway_cert_status "${cert}")"
    [[ "${status}" == "ISSUED" ]] && { log "Gateway certificate is issued."; return 0; }
    [[ "${status}" == "FAILED" || "${status}" == "VALIDATION_TIMED_OUT" || "${status}" == "REVOKED" || "${status}" == "EXPIRED" ]] && break
    sleep 15
  done
  rec="$(get_metadata "gateway_cert_validation")"
  mark_phase_blocked "The gateway certificate ${cert} is '${status:-unknown}', not ISSUED. DNS validation needs this record where $(get_metadata "gateway_domain") is hosted: ${rec:-(run phase gateway-cert to print it)}. Add it (the sheet ${HOME}/.straiker/gateway-dns-handoff-${CLUSTER_NAME}.md has it), wait a few minutes, then re-run this phase."
  return 1
}

# After the gateway is up: point the name at the load balancer (Route53 zone in this account), or print the record to add.
gateway_dns_ensure() {
  local domain host zone lbzone
  domain="$(get_metadata "gateway_domain")"
  [[ -n "${domain}" && "$(get_metadata "gateway_exposure")" == "public" ]] || return 0
  if gateway_via_alb; then
    host="$(kubectl get ingress "${EDGE_RELEASE}-xalb-api" -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  else
    host="$(kubectl get svc api-gateway -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  fi
  [[ -n "${host}" ]] || { log "WARNING: no load balancer address yet: point ${domain} at it (CNAME) once it exists."; return 0; }
  zone="$(gateway_find_zone "${domain}")"
  if [[ -z "${zone}" ]]; then
    log "ADD THIS DNS RECORD where ${domain} is hosted:  ${domain}  CNAME  ${host}"
    set_metadata "gateway_dns_record" "${domain} CNAME ${host}"
    gateway_dns_handoff
    return 0
  fi
  # A CNAME is not allowed at a zone apex: use an alias to the load balancer there.
  if [[ "$(aws route53 get-hosted-zone --id "${zone}" --query HostedZone.Name --output text 2>/dev/null)" == "${domain}." ]]; then
    lbzone="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" --query "LoadBalancers[?DNSName=='${host}'].CanonicalHostedZoneId | [0]" --output text 2>/dev/null)"
    if [[ -z "${lbzone}" || "${lbzone}" == "None" ]]; then
      log "ADD THIS DNS RECORD (an alias, ${domain} is the zone apex):  ${domain}  A ALIAS ${host}"; return 0
    fi
    aws route53 change-resource-record-sets --hosted-zone-id "${zone}" --change-batch \
      "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${domain}\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"${lbzone}\",\"DNSName\":\"${host}\",\"EvaluateTargetHealth\":false}}}]}" >/dev/null \
      || { log "WARNING: could not write the alias record for ${domain}."; return 0; }
  else
    route53_upsert "${zone}" "${domain}" CNAME "${host}" || { log "WARNING: could not write the DNS record for ${domain} (needs route53:ChangeResourceRecordSets)."; return 0; }
  fi
  log "Pointed ${domain} at the gateway load balancer (Route53 zone ${zone}). Gateway URL: https://${domain}"
}

# The gateway must never be internet-facing unless --gateway-exposure public was chosen (with TLS and, ideally, source ranges). Looks
# the load balancer up by its hostname and blocks if it is public by accident. No hostname (exposure none, or still pending): nothing
# to check yet. Also run by verify-data-layer.
gateway_lb_scheme() {
  local host=$1 scheme
  scheme="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" --query "LoadBalancers[?DNSName=='${host}'].Scheme | [0]" --output text 2>/dev/null)"
  if [[ -z "${scheme}" || "${scheme}" == "None" ]]; then
    scheme="$(aws elb describe-load-balancers --region "${AWS_REGION}" --query "LoadBalancerDescriptions[?DNSName=='${host}'].Scheme | [0]" --output text 2>/dev/null)"
  fi
  [[ "${scheme}" == "None" ]] && scheme=""
  printf '%s' "${scheme}"
}

verify_gateway_exposure() {
  local mode host="" scheme="" n
  mode="$(get_metadata "gateway_exposure")"
  [[ "${mode}" == "none" ]] && return 0
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    host="$(kubectl get svc api-gateway -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    [[ -n "${host}" ]] && break
    sleep 10
  done
  if [[ -z "${host}" ]]; then
    log "WARNING: the api-gateway load balancer has no address yet; check 'kubectl describe svc api-gateway -n ${INFRA_NAMESPACE}'."
    return 0
  fi
  scheme="$(gateway_lb_scheme "${host}")"
  if [[ "${mode}" != "public" && "${scheme}" == "internet-facing" ]]; then
    mark_phase_blocked "The api-gateway load balancer ${host} is INTERNET-FACING but --gateway-exposure is '${mode}'. An older install left it (a load balancer's scheme cannot change in place). Delete the Service so a new internal one is created, then re-run this phase: kubectl delete svc api-gateway -n ${INFRA_NAMESPACE}"
    return 1
  fi
  log "api-gateway load balancer is ${scheme:-of unknown scheme} (exposure ${mode})."
}

# Post-install checks for the AWS data tier (opt-in via --data-layer). Gate between the data
# layer and the app charts (core/ascend/defend): any FAIL blocks the run so those charts don't
# install against a broken database, Redis or model volume.
# External Secrets Operator + the ClusterSecretStore "aws-sm" (Secrets Manager, region of the cluster).
# Auth is the controller's Pod Identity role (no keys); see "eso" in the aws-data pod_identities.
phase_external_secrets() {
  require_command helm
  require_command kubectl
  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${ESO_HELM_REPO_NAME}" "${ESO_HELM_REPO_URL}" >/dev/null
  helm repo update "${ESO_HELM_REPO_NAME}" >/dev/null

  # This phase runs before Karpenter has any NodePool (straiker-system creates them later), so on a fresh cluster the only node is
  # the tainted system node: without this toleration the three pods stay Pending until Helm's wait times out. The artifact sync
  # jobs (the next phase) tolerate the same taint for the same reason.
  local eso_toleration_args=() eso_scope
  for eso_scope in "tolerations" "webhook.tolerations" "certController.tolerations"; do
    eso_toleration_args+=(
      --set-string "${eso_scope}[0].key=CriticalAddonsOnly"
      --set-string "${eso_scope}[0].operator=Equal"
      --set-string "${eso_scope}[0].value=true"
      --set-string "${eso_scope}[0].effect=NoSchedule"
    )
  done
  helm upgrade --install "${ESO_RELEASE}" "${ESO_HELM_REPO_NAME}/external-secrets" \
    --version "${ESO_VERSION}" \
    --namespace "${ESO_NAMESPACE}" \
    --create-namespace \
    --set "installCRDs=true" \
    --set "serviceAccount.name=${ESO_SERVICE_ACCOUNT}" \
    "${eso_toleration_args[@]}" \
    --wait \
    --timeout "${HELM_TIMEOUT}"

  # The webhook must be serving before the store (a CRD instance) is admitted.
  kubectl -n "${ESO_NAMESPACE}" rollout status deploy/"${ESO_RELEASE}-webhook" --timeout=180s >/dev/null

  kubectl apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: ${ESO_STORE_NAME}
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
EOF

  local i state=""
  for i in $(seq 1 30); do
    state="$(kubectl get clustersecretstore "${ESO_STORE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "${state}" == "True" ]] && break
    sleep 5
  done
  if [[ "${state}" != "True" ]]; then
    mark_phase_blocked "ClusterSecretStore '${ESO_STORE_NAME}' is not Ready. Check: kubectl describe clustersecretstore ${ESO_STORE_NAME} (the 'eso' Pod Identity role comes from phase 'aws-data'; restart the ESO pods if the role was created after they started)."
    return
  fi
  log "ESO ${ESO_VERSION} installed; ClusterSecretStore '${ESO_STORE_NAME}' is Ready."
}

# K8s Secret "opensearch-credentials" (username/password/url of the managed OpenSearch domain) synced from
# Secrets Manager "<cluster>/opensearch/main" with an ExternalSecret. Needs phase 'external-secrets'.
ensure_opensearch_credentials_secret() {
  local secret_name="$1"
  if ! kubectl get clustersecretstore "${ESO_STORE_NAME}" >/dev/null 2>&1; then
    mark_phase_blocked "ClusterSecretStore '${ESO_STORE_NAME}' not found. Run phase 'external-secrets' first."
    return 1
  fi
  kubectl apply -n "${INFRA_NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: opensearch-credentials
spec:
  refreshInterval: 1h
  secretStoreRef: {name: ${ESO_STORE_NAME}, kind: ClusterSecretStore}
  target: {name: opensearch-credentials, creationPolicy: Owner}
  data:
    - {secretKey: username, remoteRef: {key: ${secret_name}, property: username}}
    - {secretKey: password, remoteRef: {key: ${secret_name}, property: password}}
    - {secretKey: url, remoteRef: {key: ${secret_name}, property: url}}
EOF
  if ! kubectl wait externalsecret/opensearch-credentials -n "${INFRA_NAMESPACE}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    mark_phase_blocked "ExternalSecret opensearch-credentials is not Ready (secret '${secret_name}'). Check: kubectl describe externalsecret opensearch-credentials -n ${INFRA_NAMESPACE}"
    return 1
  fi
}

# Public https origin of the frontend (what the Cognito app client must allow as callback host): the custom
# domain's "straiker" host for edge types that have one, else the bundled edge's hostname.
app_origin() {
  local d
  d="$(get_metadata "custom_domain")"
  if [[ -n "${d}" && ( "${EDGE_TYPE}" == "none" || "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" || "${EDGE_TYPE}" == "tailscale" ) ]]; then
    printf 'https://%s' "$(custom_domain_hostname straiker)"
  else
    printf 'https://app.straiker.internal:8443'
  fi
}

# K8s Secret "cognito-oidc" (the app client's secret, from Secrets Manager "<cluster>/cognito/main") via an ExternalSecret.
ensure_cognito_oidc_secret() {
  local secret_name="$1"
  if ! kubectl get clustersecretstore "${ESO_STORE_NAME}" >/dev/null 2>&1; then
    mark_phase_blocked "ClusterSecretStore '${ESO_STORE_NAME}' not found. Run phase 'external-secrets' first."
    return 1
  fi
  kubectl apply -n "${INFRA_NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cognito-oidc
spec:
  refreshInterval: 1h
  secretStoreRef: {name: ${ESO_STORE_NAME}, kind: ClusterSecretStore}
  target: {name: cognito-oidc, creationPolicy: Owner}
  data:
    - {secretKey: client_secret, remoteRef: {key: ${secret_name}, property: client_secret}}
    - {secretKey: client_id, remoteRef: {key: ${secret_name}, property: client_id}}
    - {secretKey: issuer, remoteRef: {key: ${secret_name}, property: issuer}}
EOF
  if ! kubectl wait externalsecret/cognito-oidc -n "${INFRA_NAMESPACE}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    mark_phase_blocked "ExternalSecret cognito-oidc is not Ready (secret '${secret_name}'). Check: kubectl describe externalsecret cognito-oidc -n ${INFRA_NAMESPACE}"
    return 1
  fi
}

# Creates the first admin in the Cognito pool (no invitation email; permanent password from Secrets Manager
# "<cluster>/cognito/main-admin") if missing. With --reset-admin-password the password is set again (recovery:
# someone with IAM access to the pool can always get back in). The password goes through a 0600 temp file, not argv.
ensure_cognito_admin_user() {
  local email="$1" pool admin_secret tmp
  pool="$(get_metadata "cognito_pool_id")"
  admin_secret="$(get_metadata "cognito_admin_secret_name")"
  require_command aws
  require_command python3
  if [[ -z "${pool}" || -z "${admin_secret}" ]]; then
    mark_phase_blocked "No Cognito pool in install state. Run phase 'aws-data' first."
    return 1
  fi
  local exists=false
  aws cognito-idp admin-get-user --user-pool-id "${pool}" --username "${email}" --region "${AWS_REGION}" >/dev/null 2>&1 && exists=true
  if [[ "${exists}" == "true" && "${RESET_ADMIN_PASSWORD}" != "true" ]]; then
    return 0
  fi
  if [[ "${exists}" != "true" ]]; then
    aws cognito-idp admin-create-user --user-pool-id "${pool}" --username "${email}" --region "${AWS_REGION}" \
      --user-attributes "Name=email,Value=${email}" "Name=email_verified,Value=true" \
      --message-action SUPPRESS >/dev/null \
      || { mark_phase_blocked "Could not create Cognito user ${email} in pool ${pool}."; return 1; }
    log "Created Cognito admin user ${email}."
  fi
  if [[ "${ROTATE_ADMIN_PASSWORD}" == "true" ]]; then
    tmp="$(mktemp)"
    chmod 600 "${tmp}"
    python3 -c 'import json, secrets, string
sym = "!#%*-_="
while True:
    p = "".join(secrets.choice(string.ascii_letters + string.digits + sym) for _ in range(24))
    if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p) and any(c in sym for c in p):
        break
print(json.dumps({"password": p}))' > "${tmp}"
    if ! aws secretsmanager put-secret-value --secret-id "${admin_secret}" --region "${AWS_REGION}" --secret-string "file://${tmp}" >/dev/null; then
      rm -f "${tmp}"
      mark_phase_blocked "Could not store the new admin password in Secrets Manager."
      return 1
    fi
    rm -f "${tmp}"
    log "Generated a new password for ${email} in Secrets Manager."
  fi
  tmp="$(mktemp)"
  chmod 600 "${tmp}"
  aws secretsmanager get-secret-value --secret-id "${admin_secret}" --region "${AWS_REGION}" --query SecretString --output text \
    | python3 -c 'import json,sys; print(json.dumps({"UserPoolId": sys.argv[1], "Username": sys.argv[2], "Password": json.load(sys.stdin)["password"], "Permanent": True}))' "${pool}" "${email}" > "${tmp}"
  if ! aws cognito-idp admin-set-user-password --cli-input-json "file://${tmp}" --region "${AWS_REGION}" >/dev/null; then
    rm -f "${tmp}"
    mark_phase_blocked "Could not set the Cognito password for ${email}."
    return 1
  fi
  rm -f "${tmp}"
  log "Cognito password for ${email} set from Secrets Manager '${admin_secret}'."
}

# Creates or updates a Secrets Manager secret from a file (the value never goes through argv).
sm_put_secret_file() {
  local id="$1" file="$2"
  if aws secretsmanager describe-secret --secret-id "${id}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "${id}" --region "${AWS_REGION}" --secret-string "file://${file}" >/dev/null
  else
    aws secretsmanager create-secret --name "${id}" --region "${AWS_REGION}" --secret-string "file://${file}" >/dev/null
  fi
}

# Checks the provider is reachable and sane before anything is applied. SAML: the metadata (URL or file) is valid XML
# with an IdP SSO endpoint and a signing certificate that is not expired (warns under 60 days). OIDC: the discovery
# document is https, names the issuer and has the endpoints. Remembers the certificate's end date for the verify phase.
# $1 = Cognito type, $2 = metadata URL, $3 = metadata file, $4 = issuer.
sso_preflight() {
  local ctype="$1" url="$2" file="$3" issuer="$4" tmp out
  require_command curl
  require_command openssl
  require_command python3
  tmp="$(mktemp)"
  chmod 600 "${tmp}"
  case "${ctype}" in
    SAML)
      if [[ -n "${url}" ]]; then
        if ! curl -fsS --max-time 20 --proto '=https' -o "${tmp}" "${url}" 2>/dev/null; then
          rm -f "${tmp}"
          mark_phase_blocked "The SAML metadata URL is not reachable from here (${url}). Cognito fetches it from AWS, so it must be public: use --sso-saml-metadata-file for a private provider, or --skip-sso-preflight if only this machine cannot reach it."
          return 1
        fi
      else
        cp "${file}" "${tmp}"
      fi
      if ! out="$(python3 -W ignore -c '
import datetime, re, subprocess, sys
import xml.etree.ElementTree as ET
x = open(sys.argv[1], encoding="utf-8").read()
try:
    root = ET.fromstring(x)
except ET.ParseError as e:
    print("the SAML metadata is not valid XML (%s)" % e); sys.exit(1)
if "IDPSSODescriptor" not in x or "SingleSignOnService" not in x:
    print("the SAML metadata has no IDPSSODescriptor / SingleSignOnService (is it the identity provider metadata?)"); sys.exit(1)
ends = []
for c in re.findall(r"<(?:\w+:)?X509Certificate>\s*([^<]+?)\s*</", x):
    pem = "-----BEGIN CERTIFICATE-----\n" + "\n".join(re.findall(".{1,64}", re.sub(r"\s+", "", c))) + "\n-----END CERTIFICATE-----\n"
    r = subprocess.run(["openssl", "x509", "-noout", "-enddate"], input=pem, capture_output=True, text=True)
    if r.returncode == 0:
        ends.append(datetime.datetime.strptime(r.stdout.strip().split("=")[1], "%b %d %H:%M:%S %Y %Z"))
if not ends:
    print("the SAML metadata has no readable signing certificate"); sys.exit(1)
last = max(ends)
days = (last - datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)).days
if days < 0:
    print("every signing certificate in the SAML metadata has expired (%s)" % last.date()); sys.exit(1)
print("%d %s" % (days, last.date()))
' "${tmp}" 2>&1)"; then
        rm -f "${tmp}"
        mark_phase_blocked "SAML metadata check failed: ${out}"
        return 1
      fi
      set_metadata "sso_cert_not_after" "${out#* }"
      if [[ "${out%% *}" -lt 60 ]]; then
        log "WARN  The SAML signing certificate expires in ${out%% *} days (${out#* }); ask the customer to rotate it and re-run phase aws-data with the new metadata."
      else
        log "SAML metadata OK; signing certificate valid until ${out#* }."
      fi
      ;;
    OIDC)
      if ! curl -fsS --max-time 20 --proto '=https' -o "${tmp}" "${issuer%/}/.well-known/openid-configuration" 2>/dev/null; then
        rm -f "${tmp}"
        mark_phase_blocked "The OIDC discovery document is not reachable (${issuer%/}/.well-known/openid-configuration). Cognito fetches it from AWS, so the issuer must be public; use --skip-sso-preflight if only this machine cannot reach it."
        return 1
      fi
      if ! out="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
iss = sys.argv[2].rstrip("/")
if str(d.get("issuer", "")).rstrip("/") != iss:
    print("the discovery document names issuer %r, not %r" % (d.get("issuer"), iss)); sys.exit(1)
for k in ("authorization_endpoint", "token_endpoint", "jwks_uri"):
    if not str(d.get(k, "")).startswith("https://"):
        print("the discovery document has no https %s" % k); sys.exit(1)
print("ok")
' "${tmp}" "${issuer}" 2>&1)"; then
        rm -f "${tmp}"
        mark_phase_blocked "OIDC discovery check failed: ${out}"
        return 1
      fi
      log "OIDC discovery OK for ${issuer}."
      ;;
  esac
  rm -f "${tmp}"
}

# Validates and remembers the customer's SSO settings (flags -> install state); secrets go to Secrets Manager
# (<cluster>/cognito/sso-credentials). Run before the Cognito pool is applied.
remember_sso_settings() {
  [[ -n "${SSO_TYPE}${SSO_NAME}${SSO_SAML_METADATA_URL}${SSO_SAML_METADATA_FILE}${SSO_OIDC_ISSUER}" ]] || return 0
  local type ctype name
  type="$(printf '%s' "${SSO_TYPE}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${type}" ]]; then
    if [[ -n "${SSO_SAML_METADATA_URL}${SSO_SAML_METADATA_FILE}" ]]; then type=saml; elif [[ -n "${SSO_OIDC_ISSUER}" ]]; then type=oidc; fi
  fi
  case "${type}" in
    google) ctype=Google; name=Google ;;
    facebook) ctype=Facebook; name=Facebook ;;
    amazon) ctype=LoginWithAmazon; name=LoginWithAmazon ;;
    apple) ctype=SignInWithApple; name=SignInWithApple ;;
    saml) ctype=SAML; name="${SSO_NAME}" ;;
    oidc) ctype=OIDC; name="${SSO_NAME}" ;;
    *)
      mark_phase_blocked "--sso-type must be one of google, facebook, amazon, apple, saml, oidc."
      return 1
      ;;
  esac
  if [[ "${ctype}" == "SAML" || "${ctype}" == "OIDC" ]]; then
    if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{1,30}[A-Za-z0-9]$ ]] || [[ "${name}" =~ ^(COGNITO|Google|Facebook|LoginWithAmazon|SignInWithApple)$ ]]; then
      mark_phase_blocked "--sso-name is required for saml/oidc: 3-32 letters, digits or hyphens (no underscore), not a built-in provider name."
      return 1
    fi
  fi
  if [[ -z "${SSO_DOMAINS}" ]]; then
    mark_phase_blocked "SSO needs --sso-domains <a.com,b.com> (the email domains allowed to sign in through SSO)."
    return 1
  fi
  local d
  for d in ${SSO_DOMAINS//,/ }; do
    if [[ ! "${d}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
      mark_phase_blocked "--sso-domains: '${d}' is not a valid domain."
      return 1
    fi
  done

  # A different provider than the one already set up orphans the users who signed in through it.
  local prev_name prev_type
  prev_name="$(get_metadata "sso_name")"
  prev_type="$(get_metadata "sso_type")"
  if [[ -n "${prev_name}" && ( "${prev_name}" != "${name}" || "${prev_type}" != "${ctype}" ) && "${ALLOW_SSO_CHANGE}" != "true" ]]; then
    mark_phase_blocked "SSO provider '${prev_name}' (${prev_type}) is already set up; switching to '${name}' (${ctype}) orphans the users who signed in through it. Re-run with --allow-sso-change to do it anyway."
    return 1
  fi

  # Per-type inputs.
  local meta_file="" cs="${SSO_CLIENT_SECRET:-${SSO_OIDC_CLIENT_SECRET:-}}" apple_key="${SSO_APPLE_PRIVATE_KEY:-}"
  case "${ctype}" in
    SAML)
      if [[ -n "${SSO_SAML_METADATA_URL}" && ! "${SSO_SAML_METADATA_URL}" =~ ^https:// ]]; then
        mark_phase_blocked "--sso-saml-metadata-url must be https."
        return 1
      fi
      if [[ -z "${SSO_SAML_METADATA_URL}" && -z "${SSO_SAML_METADATA_FILE}" ]]; then
        mark_phase_blocked "SAML needs --sso-saml-metadata-url <https url> or --sso-saml-metadata-file <xml>."
        return 1
      fi
      if [[ -n "${SSO_SAML_METADATA_FILE}" && ! -r "${SSO_SAML_METADATA_FILE}" ]]; then
        mark_phase_blocked "Cannot read --sso-saml-metadata-file ${SSO_SAML_METADATA_FILE}."
        return 1
      fi
      meta_file="${SSO_SAML_METADATA_FILE}"
      ;;
    OIDC)
      if [[ ! "${SSO_OIDC_ISSUER}" =~ ^https:// || -z "${SSO_CLIENT_ID}" ]]; then
        mark_phase_blocked "OIDC needs --sso-oidc-issuer <https url> and --sso-client-id <id> (secret in env SSO_CLIENT_SECRET)."
        return 1
      fi
      ;;
    SignInWithApple)
      if [[ -n "${SSO_APPLE_PRIVATE_KEY_FILE}" ]]; then
        [[ -r "${SSO_APPLE_PRIVATE_KEY_FILE}" ]] || { mark_phase_blocked "Cannot read --sso-apple-private-key-file."; return 1; }
        apple_key="$(cat "${SSO_APPLE_PRIVATE_KEY_FILE}")"
      fi
      if [[ -z "${SSO_CLIENT_ID}" || -z "${SSO_APPLE_TEAM_ID}" || -z "${SSO_APPLE_KEY_ID}" ]]; then
        mark_phase_blocked "Sign in with Apple needs --sso-client-id (Services ID), --sso-apple-team-id, --sso-apple-key-id and the private key (--sso-apple-private-key-file or env SSO_APPLE_PRIVATE_KEY)."
        return 1
      fi
      if [[ -n "${apple_key}" && "${apple_key}" != *"BEGIN PRIVATE KEY"* ]]; then
        mark_phase_blocked "The Apple private key is not a PEM (.p8) key."
        return 1
      fi
      ;;
    *)
      if [[ -z "${SSO_CLIENT_ID}" ]]; then
        mark_phase_blocked "${ctype} needs --sso-client-id (secret in env SSO_CLIENT_SECRET)."
        return 1
      fi
      ;;
  esac

  # Secrets: new values go to Secrets Manager; otherwise the stored ones must exist (prompt on a terminal).
  local sid="${CLUSTER_NAME}/cognito/sso-credentials"
  if [[ "${ctype}" != "SAML" ]]; then
    local stored=false
    aws secretsmanager describe-secret --secret-id "${sid}" --region "${AWS_REGION}" >/dev/null 2>&1 && stored=true
    if [[ -z "${cs}" && -z "${apple_key}" && "${stored}" != "true" ]]; then
      if [[ -t 0 && "${ctype}" != "SignInWithApple" ]]; then
        read -rsp "Client secret for ${name}: " cs || true
        echo
      fi
      if [[ -z "${cs}" ]]; then
        mark_phase_blocked "${ctype} needs its secret: env SSO_CLIENT_SECRET (or SSO_APPLE_PRIVATE_KEY / --sso-apple-private-key-file for Apple)."
        return 1
      fi
    fi
    if [[ -n "${cs}" || -n "${apple_key}" ]]; then
      local stmp
      stmp="$(mktemp)"
      chmod 600 "${stmp}"
      CS="${cs}" AK="${apple_key}" python3 -c 'import json, os; print(json.dumps({"client_secret": os.environ["CS"], "apple_private_key": os.environ["AK"]}))' > "${stmp}"
      if ! sm_put_secret_file "${sid}" "${stmp}"; then
        rm -f "${stmp}"
        mark_phase_blocked "Could not store the SSO credentials in Secrets Manager (${sid})."
        return 1
      fi
      rm -f "${stmp}"
    fi
  fi

  if [[ "${ctype}" == "SAML" && -n "${meta_file}" ]]; then
    mkdir -p "${HOME}/.straiker"
    cp "${meta_file}" "${HOME}/.straiker/sso-metadata-${CLUSTER_NAME}.xml"
    chmod 600 "${HOME}/.straiker/sso-metadata-${CLUSTER_NAME}.xml"
    set_metadata "sso_saml_metadata_file" "${HOME}/.straiker/sso-metadata-${CLUSTER_NAME}.xml"
  elif [[ "${ctype}" == "SAML" ]]; then
    set_metadata "sso_saml_metadata_file" ""
  fi

  if [[ "${SKIP_SSO_PREFLIGHT}" != "true" && ( "${ctype}" == "SAML" || "${ctype}" == "OIDC" ) ]]; then
    sso_preflight "${ctype}" "${SSO_SAML_METADATA_URL}" "${meta_file}" "${SSO_OIDC_ISSUER}" || return 1
  fi

  set_metadata "sso_name" "${name}"
  set_metadata "sso_type" "${ctype}"
  set_metadata "sso_saml_metadata_url" "${SSO_SAML_METADATA_URL}"
  set_metadata "sso_oidc_issuer" "${SSO_OIDC_ISSUER}"
  set_metadata "sso_client_id" "${SSO_CLIENT_ID}"
  set_metadata "sso_email_claim" "${SSO_EMAIL_CLAIM}"
  set_metadata "sso_domains" "${SSO_DOMAINS}"
  set_metadata "sso_apple_team_id" "${SSO_APPLE_TEAM_ID}"
  set_metadata "sso_apple_key_id" "${SSO_APPLE_KEY_ID}"
}

# JSON for Terraform's cognito_identity_providers from the remembered settings ({} when none). Secrets are read from
# Secrets Manager; the result goes to tofu through TF_VAR (never argv or a file).
sso_identity_providers_json() {
  local name type
  name="$(get_metadata "sso_name")"
  if [[ -z "${name}" ]]; then
    printf '{}'
    return 0
  fi
  type="$(get_metadata "sso_type")"
  local creds="{}" meta_xml=""
  if [[ "${type}" != "SAML" ]]; then
    creds="$(aws secretsmanager get-secret-value --secret-id "${CLUSTER_NAME}/cognito/sso-credentials" --region "${AWS_REGION}" --query SecretString --output text 2>/dev/null || echo '{}')"
  elif [[ -n "$(get_metadata "sso_saml_metadata_file")" && -r "$(get_metadata "sso_saml_metadata_file")" ]]; then
    meta_xml="$(cat "$(get_metadata "sso_saml_metadata_file")")"
  fi
  NAME="${name}" TYPE="${type}" SAML="$(get_metadata "sso_saml_metadata_url")" META_XML="${meta_xml}" \
    ISSUER="$(get_metadata "sso_oidc_issuer")" CLIENT="$(get_metadata "sso_client_id")" CREDS="${creds}" \
    CLAIM="$(get_metadata "sso_email_claim")" DOMAINS="$(get_metadata "sso_domains")" \
    TEAM="$(get_metadata "sso_apple_team_id")" KEY="$(get_metadata "sso_apple_key_id")" python3 -c '
import json, os
e = os.environ
c = json.loads(e["CREDS"] or "{}")
p = {"type": e["TYPE"], "domains": [d.strip() for d in e["DOMAINS"].split(",") if d.strip()]}
if e["CLAIM"]:
    p["email_claim"] = e["CLAIM"]
if e["TYPE"] == "SAML":
    if e["SAML"]:
        p["saml_metadata_url"] = e["SAML"]
    else:
        p["saml_metadata_file"] = e["META_XML"]
else:
    p["client_id"] = e["CLIENT"]
    if e["TYPE"] == "OIDC":
        p["oidc_issuer"] = e["ISSUER"]
    if e["TYPE"] == "SignInWithApple":
        p.update({"apple_team_id": e["TEAM"], "apple_key_id": e["KEY"], "apple_private_key": c.get("apple_private_key", "")})
    else:
        p["client_secret"] = c.get("client_secret", "")
print(json.dumps({e["NAME"]: p}))'
}

# Writes the hand-over sheet for the customer's IT (no secrets): what to register in their provider, and what to send
# back. Per provider type; the values come from the Cognito outputs in install state.
write_sso_handoff() {
  local name type file acs eid redir domains
  name="$(get_metadata "sso_name")"
  [[ -n "${name}" ]] || return 0
  type="$(get_metadata "sso_type")"
  acs="$(get_metadata "cognito_saml_acs_url")"
  eid="$(get_metadata "cognito_entity_id")"
  redir="$(get_metadata "cognito_oidc_redirect_uri")"
  domains="$(get_metadata "sso_domains")"
  mkdir -p "${HOME}/.straiker"
  file="${HOME}/.straiker/sso-handoff-${CLUSTER_NAME}.md"
  {
    echo "# Straiker single sign-on: setup for your identity provider (${type})"
    echo
    echo "Users with an email in these domains can sign in: ${domains}. New users get the read-only viewer role."
    echo
    case "${type}" in
      SAML)
        echo "Register Straiker as a SAML application (service provider) in your identity provider:"
        echo
        echo "- Single sign-on URL / ACS URL: ${acs}"
        echo "- Audience URI / Entity ID: ${eid}"
        echo "- Name ID format: EmailAddress"
        echo "- Send the user's email as the attribute \`$(get_metadata "sso_email_claim")\` (default: http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress)"
        echo "- Sign the assertion (Okta, Entra, ADFS and OneLogin do by default)"
        echo
        echo "Then send us the identity provider's metadata (URL, or the XML file if it is not public)."
        echo "Cognito fetches a metadata URL from the internet, so it must be publicly reachable."
        ;;
      OIDC)
        echo "Register Straiker as an OpenID Connect web application (confidential client, authorization code flow):"
        echo
        echo "- Redirect (callback) URI: ${redir}"
        echo "- Scopes: openid email profile"
        echo "- Make sure ID tokens carry the user's email (claim \`$(get_metadata "sso_email_claim")\` if not the standard \`email\`)"
        echo
        echo "Then send us the issuer URL, client ID and client secret. The issuer must be publicly reachable."
        ;;
      Google)
        echo "In Google Cloud Console > APIs & Services > Credentials, create an OAuth client ID (Web application):"
        echo
        echo "- Authorized redirect URI: ${redir}"
        echo "- Scopes: openid, email, profile (OAuth consent screen: Internal for a Workspace-only audience)"
        echo
        echo "Then send us the client ID and client secret."
        ;;
      Facebook)
        echo "In Meta for Developers, create an app with the Facebook Login product:"
        echo
        echo "- Valid OAuth redirect URI: ${redir}"
        echo "- Permissions: public_profile, email"
        echo
        echo "Then send us the App ID and App secret."
        ;;
      LoginWithAmazon)
        echo "In the Login with Amazon console, create a security profile and a web application:"
        echo
        echo "- Allowed return URL: ${redir}"
        echo "- Scope: profile"
        echo
        echo "Then send us the Client ID and Client secret."
        ;;
      SignInWithApple)
        echo "In the Apple Developer account, create a Services ID with Sign in with Apple and a key:"
        echo
        echo "- Return URL: ${redir}"
        echo "- Domain: the host of that URL"
        echo "- Scopes: email, name"
        echo
        echo "Then send us the Services ID, Team ID, Key ID and the .p8 private key."
        ;;
    esac
    echo
    echo "Do not email the client secret or private key: share them through your password manager or secure channel."
  } > "${file}"
  chmod 600 "${file}"
  set_metadata "sso_handoff_file" "${file}"
}

# Validates and remembers the SES domain, and decides once how its DNS is handled: an existing public Route53 zone of
# this account (the longest zone name the domain falls under), else a zone created for the domain. The choice is
# remembered: a zone created by Terraform must never be reclassified as "existing" (Terraform would destroy it).
remember_ses_settings() {
  if [[ -n "${SES_IDENTITY_ARN}" || -n "${SES_FROM}" || -n "${SES_CONFIGURATION_SET}" ]]; then
    if [[ -n "${SES_DOMAIN}" || -n "$(get_metadata "ses_domain")" ]]; then
      mark_phase_blocked "--ses-identity-arn (the customer's own SES) cannot be combined with --ses-domain (an SES domain created by this installer, now or earlier)."
      return 1
    fi
    if [[ -z "${SES_IDENTITY_ARN}" || -z "${SES_FROM}" ]]; then
      mark_phase_blocked "The customer's own SES needs both --ses-identity-arn <arn> and --ses-from <address>."
      return 1
    fi
    if [[ ! "${SES_IDENTITY_ARN}" =~ ^arn:aws[a-z-]*:ses:[a-z0-9-]+:[0-9]{12}:identity/.+$ ]]; then
      mark_phase_blocked "--ses-identity-arn must look like arn:aws:ses:<region>:<account>:identity/<domain-or-address>."
      return 1
    fi
    if [[ ! "${SES_FROM}" =~ ^[^@[:space:]\<\>]+@[^@[:space:]\<\>]+\.[^@[:space:]\<\>]+$ ]]; then
      mark_phase_blocked "--ses-from must be an email address."
      return 1
    fi
    local ses_id_name="${SES_IDENTITY_ARN##*identity/}"
    if [[ "${SES_FROM}" != *"@${ses_id_name}" && "${SES_FROM}" != "${ses_id_name}" && "${SES_FROM}" != *"@${ses_id_name#*@}" ]]; then
      log "WARN  ${SES_FROM} does not look like it belongs to the SES identity ${ses_id_name}: SES rejects mail from addresses outside the identity."
    fi
    set_metadata "ses_existing_arn" "${SES_IDENTITY_ARN}"
    set_metadata "ses_from" "${SES_FROM}"
    set_metadata "ses_configuration_set" "${SES_CONFIGURATION_SET}"
    return 0
  fi
  if [[ -n "${SES_DOMAIN}" && -n "$(get_metadata "ses_existing_arn")" ]]; then
    mark_phase_blocked "--ses-domain cannot be combined with the customer's own SES identity already set up (${SES_DOMAIN} vs $(get_metadata "ses_existing_arn"))."
    return 1
  fi
  [[ -n "${SES_DOMAIN}" ]] || return 0
  set_metadata "ses_domain" "${SES_DOMAIN}"
  if [[ -n "$(get_metadata "ses_zone_mode")" && -z "${SES_ROUTE53_ZONE_ID}" ]]; then
    return 0
  fi
  local zone_id="${SES_ROUTE53_ZONE_ID}"
  if [[ -z "${zone_id}" ]]; then
    zone_id="$(aws route53 list-hosted-zones --output json | DOMAIN="${SES_DOMAIN}" python3 -c '
import json, os, sys
d = os.environ["DOMAIN"].rstrip(".").lower()
best = None
for z in json.load(sys.stdin)["HostedZones"]:
    if z["Config"].get("PrivateZone"):
        continue
    n = z["Name"].rstrip(".").lower()
    if (d == n or d.endswith("." + n)) and (best is None or len(n) > len(best[0])):
        best = (n, z["Id"].split("/")[-1])
print(best[1] if best else "")')"
  fi
  if [[ -n "${zone_id}" ]]; then
    set_metadata "ses_zone_mode" "existing"
    set_metadata "ses_zone_id" "${zone_id}"
    log "SES DNS records go into the existing Route53 zone ${zone_id}."
  else
    set_metadata "ses_zone_mode" "create"
    set_metadata "ses_zone_id" ""
    log "No public Route53 zone covers ${SES_DOMAIN}: one will be created; delegate its name servers from the parent zone."
  fi
}

# JSON for Terraform's ses_domains from the remembered settings ({} when none).
ses_domains_json() {
  local domain mode zone
  domain="$(get_metadata "ses_domain")"
  if [[ -z "${domain}" ]]; then
    printf '{}'
    return 0
  fi
  mode="$(get_metadata "ses_zone_mode")"
  zone="$(get_metadata "ses_zone_id")"
  DOMAIN="${domain}" MODE="${mode}" ZONE="${zone}" python3 -c '
import json, os
e = os.environ
d = {"domain": e["DOMAIN"]}
if e["MODE"] == "create":
    d["create_route53_zone"] = True
elif e["ZONE"]:
    d["route53_zone_id"] = e["ZONE"]
print(json.dumps({"main": d}))'
}

# JSON for Terraform's ses_existing from the remembered settings ("null" when none).
ses_existing_json() {
  local arn
  arn="$(get_metadata "ses_existing_arn")"
  if [[ -z "${arn}" ]]; then
    printf 'null'
    return 0
  fi
  ARN="${arn}" FROM="$(get_metadata "ses_from")" CS="$(get_metadata "ses_configuration_set")" python3 -c '
import json, os
e = os.environ
d = {"identity_arn": e["ARN"], "from_address": e["FROM"]}
if e["CS"]:
    d["configuration_set"] = e["CS"]
print(json.dumps(d))'
}

# True when SES reports the SES identity verified for sending (the installer-created domain or the customer's own).
# An identity of another account cannot be queried from here: it is assumed usable (the sending authorization is the
# customer's step) and Cognito reports a failure if not.
ses_identity_verified() {
  local domain status arn name acct region caller
  arn="$(get_metadata "ses_existing_arn")"
  if [[ -n "${arn}" ]]; then
    name="${arn##*identity/}"
    region="$(printf '%s' "${arn}" | cut -d: -f4)"
    acct="$(printf '%s' "${arn}" | cut -d: -f5)"
    caller="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
    if [[ "${acct}" != "${caller}" ]]; then
      return 0
    fi
    status="$(aws sesv2 get-email-identity --email-identity "${name}" --region "${region}" --query VerifiedForSendingStatus --output text 2>/dev/null || true)"
    [[ "${status}" == "True" ]]
    return
  fi
  domain="$(get_metadata "ses_domain")"
  [[ -n "${domain}" ]] || return 1
  status="$(aws sesv2 get-email-identity --email-identity "${domain}" --region "${AWS_REGION}" --query VerifiedForSendingStatus --output text 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

# Chart reference for an installer-owned chart: the in-workspace copy (so local chart changes apply at once,
# as for the artifact/infra/data charts), unless --chart-version pins the published one or the bundle has no charts/.
chart_ref() {
  local name="$1"
  if [[ -z "${CHART_VERSION}" && -d "${REPO_ROOT}/charts/${name}" ]]; then
    printf '%s' "${REPO_ROOT}/charts/${name}"
  else
    printf '%s' "${HELM_REPO_NAME}/${name}"
  fi
}

# K8s Secret <name> (username/password of an Aurora cluster's RDS-managed master login) synced straight from
# the RDS secret with an ExternalSecret, so it follows RDS's automatic password rotation.
ensure_aurora_admin_secret() {
  local name="$1" arn="$2"
  if ! kubectl get clustersecretstore "${ESO_STORE_NAME}" >/dev/null 2>&1; then
    mark_phase_blocked "ClusterSecretStore '${ESO_STORE_NAME}' not found. Run phase 'external-secrets' first."
    return 1
  fi
  # A Secret from before ESO (created by kubectl) has no owner; drop it so ESO creates its own.
  if kubectl get secret "${name}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1 \
     && [[ -z "$(kubectl get secret "${name}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)" ]]; then
    kubectl delete secret "${name}" -n "${INFRA_NAMESPACE}" >/dev/null
  fi
  kubectl apply -n "${INFRA_NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${name}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: ${ESO_STORE_NAME}, kind: ClusterSecretStore}
  target: {name: ${name}, creationPolicy: Owner}
  data:
    - {secretKey: username, remoteRef: {key: "${arn}", property: username}}
    - {secretKey: password, remoteRef: {key: "${arn}", property: password}}
EOF
  if ! kubectl wait externalsecret/"${name}" -n "${INFRA_NAMESPACE}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    mark_phase_blocked "ExternalSecret ${name} is not Ready. Check: kubectl describe externalsecret ${name} -n ${INFRA_NAMESPACE} (the 'eso' role needs read on the RDS master secret; re-run phase 'aws-data')."
    return 1
  fi
}

# Sync iris's Valkey connection details (Secrets Manager "<cluster>/iris/redis") into the K8s Secret
# "iris-redis" with an ExternalSecret, as SaaS does. Needs phase 'external-secrets'. Marks the phase
# blocked on failure.
ensure_iris_redis_secret() {
  local secret_name="$1"
  if ! kubectl get clustersecretstore "${ESO_STORE_NAME}" >/dev/null 2>&1; then
    mark_phase_blocked "ClusterSecretStore '${ESO_STORE_NAME}' not found. Run phase 'external-secrets' first."
    return 1
  fi
  # A Secret from before ESO (created by kubectl) has no owner; drop it so ESO creates its own.
  if kubectl get secret iris-redis -n "${INFRA_NAMESPACE}" >/dev/null 2>&1 \
     && [[ -z "$(kubectl get secret iris-redis -n "${INFRA_NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)" ]]; then
    kubectl delete secret iris-redis -n "${INFRA_NAMESPACE}" >/dev/null
  fi
  kubectl apply -n "${INFRA_NAMESPACE}" -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: iris-redis
spec:
  refreshInterval: 1h
  secretStoreRef: {name: ${ESO_STORE_NAME}, kind: ClusterSecretStore}
  target: {name: iris-redis, creationPolicy: Owner}
  data:
    - {secretKey: REDIS_URL, remoteRef: {key: ${secret_name}, property: url}}
    - {secretKey: REDIS_HOST, remoteRef: {key: ${secret_name}, property: host}}
    - {secretKey: REDIS_PORT, remoteRef: {key: ${secret_name}, property: port}}
    - {secretKey: REDIS_AUTH_TOKEN, remoteRef: {key: ${secret_name}, property: auth_token}}
    - {secretKey: REDIS_TLS_ENABLED, remoteRef: {key: ${secret_name}, property: tls}}
EOF
  if ! kubectl wait externalsecret/iris-redis -n "${INFRA_NAMESPACE}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    mark_phase_blocked "ExternalSecret iris-redis is not Ready (secret '${secret_name}'). Check: kubectl describe externalsecret iris-redis -n ${INFRA_NAMESPACE}"
    return 1
  fi
}

phase_verify_data_layer() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    log "--data-layer not set — skipping data-layer verification."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  require_command kubectl
  require_command python3
  ensure_k8s_ready_for_charts || return

  local ecr_registry aurora_host redis_endpoint
  ecr_registry="$(get_metadata "ecr_registry")"
  aurora_host="$(get_metadata "aurora_endpoint")"
  redis_endpoint="$(get_metadata "data_redis_endpoint")"
  if [[ -z "${ecr_registry}" || -z "${aurora_host}" || -z "${redis_endpoint}" ]]; then
    mark_phase_blocked "Missing ecr_registry/aurora_endpoint/data_redis_endpoint in install state. Run phases 'aws-artifacts' and 'aws-data' first."
    return
  fi
  local registry_prefixed
  registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"

  # Bash 3.2 (macOS /bin/bash) has no safe empty-array expansion, so count failures instead.
  local fail_count=0
  local result pvc_phase

  log "Verifying data layer..."

  # 1. EFS CSI driver — the models PVC mounts through it; without it pods can't mount.
  if kubectl get csidriver efs.csi.aws.com >/dev/null 2>&1; then
    log "PASS  EFS CSI driver (efs.csi.aws.com) is installed."
  else
    log "FAIL  EFS CSI driver (efs.csi.aws.com) is not installed. Install the aws-efs-csi-driver EKS addon (with a Pod Identity role for EFS) so the models volume can mount."
    fail_count=$((fail_count + 1))
  fi

  pvc_phase="$(kubectl get pvc models-filestore-pvc -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${pvc_phase}" == "Bound" ]]; then
    log "PASS  models-filestore-pvc is Bound."
  else
    log "FAIL  models-filestore-pvc is '${pvc_phase:-missing}', expected Bound."
    fail_count=$((fail_count + 1))
  fi

  # 2. ElastiCache accepts TLS (rediss://). Serverless caches are TLS-only.
  kubectl delete pod verify-redis -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  result="$(kubectl run verify-redis -n "${INFRA_NAMESPACE}" --image="${registry_prefixed}/valkey/valkey:8-alpine" \
    --restart=Never --rm -i --quiet -- valkey-cli --tls -h "${redis_endpoint}" -p 6379 PING </dev/null 2>&1 || true)"
  if printf '%s\n' "${result}" | grep -qx 'PONG'; then
    log "PASS  ElastiCache (${redis_endpoint}) answers PING over TLS."
  else
    log "FAIL  ElastiCache did not answer PING over TLS (${redis_endpoint}): ${result}"
    fail_count=$((fail_count + 1))
  fi

  # 2b. iris's node-based Valkey: TLS + AUTH (token from the K8s Secret via env, never on the command line).
  local iris_redis_host
  iris_redis_host="$(get_metadata "iris_redis_endpoint")"
  if [[ -n "${iris_redis_host}" ]]; then
    ensure_iris_redis_secret "$(get_metadata "iris_redis_secret_name")" || return
    kubectl delete pod verify-iris-redis -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    result="$(kubectl run verify-iris-redis -n "${INFRA_NAMESPACE}" --image="${registry_prefixed}/valkey/valkey:8-alpine" \
      --restart=Never --rm -i --quiet \
      --overrides='{"spec":{"containers":[{"name":"verify-iris-redis","image":"'"${registry_prefixed}"'/valkey/valkey:8-alpine","command":["valkey-cli","--tls","-h","'"${iris_redis_host}"'","-p","6379","PING"],"env":[{"name":"REDISCLI_AUTH","valueFrom":{"secretKeyRef":{"name":"iris-redis","key":"REDIS_AUTH_TOKEN"}}}],"stdin":true}]}}' \
      </dev/null 2>&1 || true)"
    if printf '%s\n' "${result}" | grep -qx 'PONG'; then
      log "PASS  iris Valkey (${iris_redis_host}) answers PING over TLS with AUTH."
    else
      log "FAIL  iris Valkey did not answer PING over TLS with AUTH (${iris_redis_host}); needs the iris-redis Secret (phase 'straiker-ascend'): ${result}"
      fail_count=$((fail_count + 1))
    fi
  fi

  # 2b'. Managed OpenSearch answers _cluster/health (green/yellow) with the master login from the K8s Secret.
  local os_host
  os_host="$(get_metadata "opensearch_endpoint")"
  if [[ -n "${os_host}" ]]; then
    ensure_opensearch_credentials_secret "$(get_metadata "opensearch_secret_name")" || return
    local os_try
    # This check runs minutes after the domain's last change and right after other workloads started: the probe pod can be slow to
    # start (image pull, node scale-up) and a single-node domain can answer late. Retry before calling it a failure.
    for os_try in 1 2 3 4; do
    kubectl delete pod verify-opensearch -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    result="$(kubectl run verify-opensearch -n "${INFRA_NAMESPACE}" --image="curlimages/curl:8.11.0" \
      --restart=Never --rm -i --quiet \
      --overrides='{"spec":{"containers":[{"name":"verify-opensearch","image":"curlimages/curl:8.11.0","command":["sh","-c","curl -s --max-time 20 -u \"$OS_USER:$OS_PASS\" https://'"${os_host}"'/_cluster/health"],"env":[{"name":"OS_USER","valueFrom":{"secretKeyRef":{"name":"opensearch-credentials","key":"username"}}},{"name":"OS_PASS","valueFrom":{"secretKeyRef":{"name":"opensearch-credentials","key":"password"}}}],"stdin":true}]}}' \
      </dev/null 2>&1 || true)"
      printf '%s' "${result}" | grep -qE '"status":"(green|yellow)"' && break
      [[ ${os_try} -lt 4 ]] && sleep 20
    done
    if printf '%s' "${result}" | grep -qE '"status":"(green|yellow)"'; then
      log "PASS  OpenSearch (${os_host}) cluster health is green/yellow with the master login."
    else
      log "FAIL  OpenSearch (${os_host}) did not report green/yellow health: ${result}"
      fail_count=$((fail_count + 1))
    fi
  fi

  # 2b''. Cognito's OIDC discovery document is reachable from the cluster and names the expected issuer.
  local cg_issuer
  cg_issuer="$(get_metadata "cognito_issuer")"
  if [[ -n "${cg_issuer}" ]]; then
    kubectl delete pod verify-cognito -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    result="$(kubectl run verify-cognito -n "${INFRA_NAMESPACE}" --image="curlimages/curl:8.11.0" \
      --restart=Never --rm -i --quiet \
      --overrides='{"spec":{"containers":[{"name":"verify-cognito","image":"curlimages/curl:8.11.0","command":["curl","-s","--max-time","20","'"${cg_issuer}"'/.well-known/openid-configuration"],"stdin":true}]}}' \
      </dev/null 2>&1 || true)"
    if printf '%s' "${result}" | grep -q "\"issuer\":\"${cg_issuer}\""; then
      log "PASS  Cognito OIDC discovery answers with issuer ${cg_issuer}."
    else
      log "FAIL  Cognito OIDC discovery did not return issuer ${cg_issuer}: ${result}"
      fail_count=$((fail_count + 1))
    fi
  fi

  # 2e. The frontend really logs in through Cognito: its OIDC issuer is Cognito's and it has no Dex endpoint override.
  if [[ -n "${cg_issuer}" ]] && kubectl get deploy straiker-frontend -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    local fe_issuer fe_authz
    fe_issuer="$(kubectl get deploy straiker-frontend -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OIDC_ISSUER")].value}' 2>/dev/null || true)"
    fe_authz="$(kubectl get deploy straiker-frontend -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OIDC_AUTHORIZATION_ENDPOINT")].value}' 2>/dev/null || true)"
    if [[ "${fe_issuer}" == "${cg_issuer}" && -z "${fe_authz}" ]]; then
      log "PASS  Frontend OIDC issuer is Cognito and uses its discovery document."
    else
      log "FAIL  Frontend OIDC is not Cognito-only (issuer '${fe_issuer}', authorization endpoint override '${fe_authz}'); re-run phase 'straiker-core' (--rerun-phase)."
      fail_count=$((fail_count + 1))
    fi
  fi

  # 2f. SES sending domain: verification and DKIM, plus the sandbox state (warnings only: DNS delegation and AWS's
  # production-access approval are outside the install).
  local ses_dom ses_info
  ses_dom="$(get_metadata "ses_domain")"
  if [[ -n "${ses_dom}" ]]; then
    ses_info="$(aws sesv2 get-email-identity --email-identity "${ses_dom}" --region "${AWS_REGION}" --query '[VerifiedForSendingStatus,DkimAttributes.Status]' --output text 2>/dev/null || true)"
    if [[ "${ses_info}" == "True"$'\t'"SUCCESS" ]]; then
      log "PASS  SES domain ${ses_dom} is verified (DKIM SUCCESS)."
    else
      log "WARN  SES domain ${ses_dom} is not verified yet (status: ${ses_info:-unknown}); check its DNS records / delegation."
    fi
    if [[ "$(aws sesv2 get-account --region "${AWS_REGION}" --query ProductionAccessEnabled --output text 2>/dev/null || true)" != "True" ]]; then
      log "WARN  SES is still in the sandbox in ${AWS_REGION}: mail only reaches verified addresses until AWS grants production access."
    fi
  fi

  # 2f'. The customer's own SES identity (same account: verified?; another account: cannot be queried from here).
  local ses_arn ses_acct ses_reg ses_name ses_caller
  ses_arn="$(get_metadata "ses_existing_arn")"
  if [[ -n "${ses_arn}" ]]; then
    ses_name="${ses_arn##*identity/}"
    ses_reg="$(printf '%s' "${ses_arn}" | cut -d: -f4)"
    ses_acct="$(printf '%s' "${ses_arn}" | cut -d: -f5)"
    ses_caller="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
    if [[ "${ses_acct}" == "${ses_caller}" ]]; then
      ses_info="$(aws sesv2 get-email-identity --email-identity "${ses_name}" --region "${ses_reg}" --query 'VerifiedForSendingStatus' --output text 2>/dev/null || true)"
      if [[ "${ses_info}" == "True" ]]; then
        log "PASS  Customer SES identity ${ses_name} is verified for sending."
      else
        log "FAIL  Customer SES identity ${ses_name} is not verified for sending (status: ${ses_info:-unknown}); Cognito cannot mail through it."
        fail_count=$((fail_count + 1))
      fi
      if [[ "$(aws sesv2 get-account --region "${ses_reg}" --query ProductionAccessEnabled --output text 2>/dev/null || true)" != "True" ]]; then
        log "WARN  SES is in the sandbox in ${ses_reg}: mail only reaches verified addresses until production access is granted."
      fi
    else
      log "WARN  Customer SES identity is in account ${ses_acct}: cannot be checked from here; confirm its sending authorization allows this account (Cognito, connect) and that it is out of the sandbox."
    fi
  fi

  # 2g. SSO: the provider is in the pool, the sign-in really redirects to it (no password needed), and a SAML
  # certificate is not about to expire.
  local sso_n sso_t
  sso_n="$(get_metadata "sso_name")"
  sso_t="$(get_metadata "sso_type")"
  if [[ -n "${sso_n}" && -n "$(get_metadata "cognito_pool_id")" ]]; then
    if aws cognito-idp describe-identity-provider --user-pool-id "$(get_metadata "cognito_pool_id")" --provider-name "${sso_n}" --region "${AWS_REGION}" >/dev/null 2>&1; then
      log "PASS  SSO provider ${sso_n} (${sso_t}) exists in the Cognito pool."
      local cg_dom cb enc_cb hdrs loc_host
      cg_dom="$(get_metadata "cognito_oidc_redirect_uri")"
      cg_dom="${cg_dom%/oauth2/idpresponse}"
      cb="$(app_origin)/login/oidc/callback"
      enc_cb="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${cb}")"
      hdrs="$(curl -s -o /dev/null -D - --max-time 20 "${cg_dom}/oauth2/authorize?client_id=$(get_metadata "cognito_client_id")&response_type=code&scope=openid+email&redirect_uri=${enc_cb}&identity_provider=${sso_n}" 2>/dev/null || true)"
      loc_host="$(printf '%s' "${hdrs}" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}' | sed -E 's#^https?://([^/]+).*#\1#' | head -1)"
      if printf '%s' "${hdrs}" | head -1 | grep -q ' 302' && [[ -n "${loc_host}" && "${cg_dom}" != *"${loc_host}"* ]]; then
        log "PASS  SSO sign-in redirects to the provider (${loc_host})."
      else
        log "FAIL  SSO sign-in does not redirect to the provider (response: $(printf '%s' "${hdrs}" | head -1 | tr -d '\r'), location host: ${loc_host:-none}); check the provider settings and the app client."
        fail_count=$((fail_count + 1))
      fi
    else
      log "FAIL  SSO provider ${sso_n} is not in the Cognito pool; re-run phase 'aws-data'."
      fail_count=$((fail_count + 1))
    fi
    local cert_end
    cert_end="$(get_metadata "sso_cert_not_after")"
    if [[ "${sso_t}" == "SAML" && -n "${cert_end}" ]]; then
      local cert_days
      cert_days="$(python3 -c 'import datetime, sys; print((datetime.date.fromisoformat(sys.argv[1]) - datetime.date.today()).days)' "${cert_end}" 2>/dev/null || echo 999)"
      if [[ "${cert_days}" -lt 0 ]]; then
        log "FAIL  The SAML signing certificate expired on ${cert_end}: SSO logins fail until the customer's new metadata is applied (phase aws-data)."
        fail_count=$((fail_count + 1))
      elif [[ "${cert_days}" -lt 60 ]]; then
        log "WARN  The SAML signing certificate expires in ${cert_days} days (${cert_end}); get the new metadata and re-run phase aws-data."
      else
        log "PASS  SAML signing certificate valid for ${cert_days} more days."
      fi
    fi
  fi

  # 2h. The Terraform state holds the Cognito client secrets and any SSO secret: its bucket must be private,
  # encrypted and versioned.
  if [[ -n "$(get_metadata "cognito_pool_id")" ]]; then
    local sb sb_enc sb_pab sb_ver
    sb="$(resolve_bucket_name 2>/dev/null || true)"
    if [[ -n "${sb}" ]]; then
      sb_enc="$(aws s3api get-bucket-encryption --bucket "${sb}" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null || true)"
      sb_pab="$(aws s3api get-public-access-block --bucket "${sb}" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text 2>/dev/null || true)"
      sb_ver="$(aws s3api get-bucket-versioning --bucket "${sb}" --query Status --output text 2>/dev/null || true)"
      if [[ "${sb_pab}" == "True"$'\t'"True"$'\t'"True"$'\t'"True" && -n "${sb_enc}" && "${sb_enc}" != "None" ]]; then
        log "PASS  Terraform state bucket ${sb} is private and encrypted (${sb_enc})."
      else
        log "FAIL  Terraform state bucket ${sb} must block public access and be encrypted (public access block: ${sb_pab:-unknown}; encryption: ${sb_enc:-none})."
        fail_count=$((fail_count + 1))
      fi
      if [[ "${sb_ver}" != "Enabled" ]]; then
        log "WARN  Terraform state bucket ${sb} is not versioned; enable versioning so a bad apply can be rolled back."
      fi
    fi
  fi

  # 2c. Ascend really uses the iris cache secret (not a default in-cluster Redis), once Ascend is installed.
  if [[ -n "${iris_redis_host}" ]] && kubectl get deploy straiker-ascend-control-plane -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    local ascend_redis_secret
    ascend_redis_secret="$(kubectl get deploy straiker-ascend-control-plane -n "${INFRA_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SYS__REDIS_URL")].valueFrom.secretKeyRef.name}' 2>/dev/null || true)"
    if [[ "${ascend_redis_secret}" == "iris-redis" ]]; then
      log "PASS  Ascend reads SYS__REDIS_URL from the iris-redis Secret."
    else
      log "FAIL  Ascend's SYS__REDIS_URL does not come from the iris-redis Secret; re-run phase 'straiker-ascend' (--rerun-phase)."
      fail_count=$((fail_count + 1))
    fi
  fi

  # 2d. Every ExternalSecret is synced.
  local es_bad
  es_bad="$(kubectl get externalsecret -A --no-headers 2>/dev/null | awk '$NF != "True" {print $1"/"$2}' | tr '\n' ' ')"
  if [[ -z "${es_bad}" ]]; then
    log "PASS  All ExternalSecrets are Ready."
  else
    log "FAIL  ExternalSecrets not Ready: ${es_bad}"
    fail_count=$((fail_count + 1))
  fi

  # 3. Every Aurora cluster accepts sslmode=require with its own application role (same DSNs the
  #    app charts use): "platform" as the frontend role, "ascend" (when present) as iris.
  local pg_overrides pg_check pg_label pg_host pg_role pg_port
  local ascend_pg_host
  pg_port="$(get_metadata "aurora_port")"
  ascend_pg_host="$(get_metadata "aurora_ascend_endpoint")"
  for pg_check in "platform|${aurora_host}|frontend" ${ascend_pg_host:+"ascend|${ascend_pg_host}|iris"}; do
    IFS='|' read -r pg_label pg_host pg_role <<<"${pg_check}"
    # --overrides replaces the whole containers array (JSON merge patch), so the command
    # must be inside it: trailing `-- psql ...` args would be dropped and the postgres
    # image would start its server instead.
    pg_overrides='{"spec":{"containers":[{"name":"verify-psql","image":"'"${registry_prefixed}"'/library/postgres:16-alpine","stdin":true,"command":["psql","host='"${pg_host}"' port='"${pg_port:-5432}"' dbname='"${pg_role}"' user='"${pg_role}"' sslmode=require","-tAc","select ssl from pg_stat_ssl where pid = pg_backend_pid();"],"env":[{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"straiker-db-dsn","key":"PASSWORD_'"${pg_role}"'"}}}]}]}}'
    kubectl delete pod verify-psql -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
    result="$(kubectl run verify-psql -n "${INFRA_NAMESPACE}" --image="${registry_prefixed}/library/postgres:16-alpine" \
      --restart=Never --rm -i --quiet --overrides="${pg_overrides}" </dev/null 2>&1 || true)"
    if printf '%s\n' "${result}" | grep -qx 't'; then
      log "PASS  Aurora '${pg_label}' accepts sslmode=require (${pg_role} role, pg_stat_ssl.ssl = t)."
    else
      log "FAIL  Aurora '${pg_label}' sslmode=require check failed: ${result}"
      fail_count=$((fail_count + 1))
    fi
  done

  # 3a. HA: nodes in every zone, and each service's replicas in more than one zone.
  if ha_enabled; then
    local want_zones have_zones svc_az
    want_zones="$(get_metadata "availability_zones" | tr ',' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
    have_zones="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
    if [[ "${want_zones}" -gt 0 && "${have_zones}" -ge "${want_zones}" ]]; then
      log "PASS  HA: nodes run in ${have_zones}/${want_zones} zones."
    else
      log "FAIL  HA: nodes run in ${have_zones:-0} of ${want_zones} zones: an Availability Zone has no node (capacity or subnet problem)."
      fail_count=$((fail_count + 1))
    fi
    svc_az="$(kubectl get pods -n "${INFRA_NAMESPACE}" -o json 2>/dev/null | python3 -c '
import json, sys
pods = json.load(sys.stdin)["items"]
nodes = json.loads(sys.argv[1])
z = {n["metadata"]["name"]: n["metadata"]["labels"].get("topology.kubernetes.io/zone", "") for n in nodes}
by = {}
for p in pods:
    if p["status"].get("phase") != "Running":
        continue
    app = p["metadata"].get("labels", {}).get("app.straiker.io/app") or p["metadata"].get("labels", {}).get("app")
    if not app:
        continue
    by.setdefault(app, []).append(z.get(p["spec"].get("nodeName", ""), ""))
for app, zs in sorted(by.items()):
    if len(zs) >= 2 and len(set(zs)) < 2:
        print(app)
' "$(kubectl get nodes -o json 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["items"]))')" 2>/dev/null || true)"
    if [[ -z "${svc_az}" ]]; then
      log "PASS  HA: every service with 2+ replicas runs them in more than one zone."
    else
      log "FAIL  HA: replicas share one zone for: $(printf '%s' "${svc_az}" | tr '\n' ' ')."
      fail_count=$((fail_count + 1))
    fi
  fi

  # 3b. ClickHouse as replicas + Keeper: every replica and Keeper member ready, no read-only replica.
  if [[ "$(clickhouse_replicated)" == "true" ]]; then
    local ch_spec ch_ready kp_spec kp_ready ch_ro
    ch_spec="$(kubectl get statefulset clickhouse -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    ch_ready="$(kubectl get statefulset clickhouse -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    kp_spec="$(kubectl get statefulset clickhouse-keeper -n "${INFRA_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    kp_ready="$(kubectl get statefulset clickhouse-keeper -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    # A replica is read-only until its Keeper session is up and its tables are attached: normal for a minute or two after the grid
    # migrations created the Replicated tables or after a restart. Give it up to 3 minutes before reporting a failure.
    local ch_try
    for ch_try in 1 2 3 4 5 6 7 8 9 10 11 12; do
      ch_ro="$(kubectl exec -n "${INFRA_NAMESPACE}" clickhouse-0 -c clickhouse -- sh -c 'clickhouse-client --user admin --password "$CH_PW_ADMIN" -q "SELECT countIf(is_readonly) FROM system.replicas"' 2>/dev/null || echo unknown)"
      ch_ready="$(kubectl get statefulset clickhouse -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
      kp_ready="$(kubectl get statefulset clickhouse-keeper -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
      [[ "${ch_ro}" == "0" && "${ch_ready:-0}" == "${ch_spec}" && "${kp_ready:-0}" == "${kp_spec}" ]] && break
      [[ ${ch_try} -lt 12 ]] && sleep 15
    done
    if [[ -n "${ch_spec}" && "${ch_ready:-0}" == "${ch_spec}" && -n "${kp_spec}" && "${kp_ready:-0}" == "${kp_spec}" && "${ch_ro}" == "0" ]]; then
      log "PASS  ClickHouse replicated: ${ch_ready}/${ch_spec} servers, ${kp_ready}/${kp_spec} Keeper members, 0 read-only replicas."
    else
      log "FAIL  ClickHouse replication: servers ${ch_ready:-0}/${ch_spec:-?}, Keeper ${kp_ready:-0}/${kp_spec:-?}, read-only replicas: ${ch_ro}."
      fail_count=$((fail_count + 1))
    fi
  fi

  # 4. No failed Jobs (data bootstrap, grid/registry migrations, ch-sync init, topics).
  local failed_jobs
  # A failed run of a CronJob (e.g. ch-sync while ClickHouse restarted) does not count once a later run of the
  # same CronJob has succeeded.
  failed_jobs="$(kubectl get jobs -n "${INFRA_NAMESPACE}" -o json 2>/dev/null | python3 -c '
import json, sys
items = json.load(sys.stdin).get("items", [])
def owner(j):
    for o in j["metadata"].get("ownerReferences", []):
        if o.get("kind") == "CronJob":
            return o["name"]
    return None
latest_ok = {}
for j in items:
    o = owner(j)
    if o and j.get("status", {}).get("succeeded", 0):
        t = j["metadata"]["creationTimestamp"]
        latest_ok[o] = max(latest_ok.get(o, ""), t)
for j in items:
    s = j.get("status", {})
    if s.get("failed", 0) and not s.get("succeeded", 0):
        o = owner(j)
        if o and latest_ok.get(o, "") > j["metadata"]["creationTimestamp"]:
            continue
        print(j["metadata"]["name"])
' || true)"
  if [[ -z "${failed_jobs}" ]]; then
    log "PASS  No failed Jobs in '${INFRA_NAMESPACE}'."
  else
    log "FAIL  Failed Jobs in '${INFRA_NAMESPACE}': $(printf '%s' "${failed_jobs}" | tr '\n' ' ')— see kubectl -n ${INFRA_NAMESPACE} logs job/<name>."
    fail_count=$((fail_count + 1))
  fi

  if [[ "${fail_count}" -gt 0 ]]; then
    mark_phase_blocked "${fail_count} data-layer check(s) failed — see the FAIL lines above. Fix, then re-run: --phase verify-data-layer --rerun-phase."
    return
  fi
  log "All data-layer checks passed."
}

# The tag the artifact chart mirrors for <repo> (from charts/straiker-artifact/values.yaml): one source of truth, so a chart can never
# ask for a tag the mirror does not carry.
mirrored_image_tag() {
  awk -v repo="onprem-base/$1" '$0 ~ "source:.*" repo "$" { found = 1; next } found && $1 == "tag:" { gsub(/"/, "", $2); print $2; exit }' \
    "${REPO_ROOT}/charts/straiker-artifact/values.yaml"
}

# Installs the vendored platform service charts (opt-in via --data-layer). Images come
# from the customer's ECR mirror; DSNs/brokers/keys from platform-secret (straiker-data).
phase_platform_services() {
  if [[ "${DATA_LAYER}" != "true" ]]; then
    log "--data-layer not set — skipping platform services."
    set_phase_status "${CURRENT_PHASE}" "skipped" "--data-layer not set."
    return
  fi
  require_command kubectl
  require_command helm
  ensure_k8s_ready_for_charts || return

  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  if [[ -z "${ecr_registry}" ]]; then
    mark_phase_blocked "No ECR registry in state. Run phase 'aws-artifacts' first."
    return
  fi
  if ! kubectl get secret platform-secret -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    mark_phase_blocked "Secret 'platform-secret' missing. Run phase 'data-bootstrap' first."
    return
  fi

  local svc chart tag key
  for svc in ${PLATFORM_SERVICES}; do
    if [[ "${svc}" == "api-gateway" ]]; then
      install_api_gateway "${ecr_registry}" || return
      continue
    fi
    chart="${REPO_ROOT}/charts/platform-${svc}"
    [[ -d "${chart}" ]] || { mark_phase_blocked "Unknown platform service '${svc}' (no ${chart})."; return; }
    tag="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${chart}/Chart.yaml")"
    key="straiker.${svc}"
    local -a extra=()
    case "${svc}" in
      foundation) extra+=(--set-string "${key}.bus.saslRegion=${AWS_REGION}") ;;
      registry)
        extra+=(--set-string "${key}.bus.sasl.region=${AWS_REGION}" --set-string "${key}.secrets.prefix=${CLUSTER_NAME}/platform/integration/")
        # Argus control catalog (Controls page, default policies): fetched through the gateway's /internal/argus tier with
        # REGISTRY_GATEWAY_S2S_KEY (platform-secret). Without the URL the surface is off ("control catalog is unavailable").
        extra+=(--set-string "${key}.gateway.url=http://api-gateway.${INFRA_NAMESPACE}.svc.cluster.local:443")
        ;;
      databridge)
        # The chart pins docker.redpanda.com/redpandadata/connect:<tag>, a public pull at runtime (breaks locked-down egress and the
        # "every image from the customer's registry" rule): use the mirrored copy, at the tag the mirror list carries.
        extra+=(--set-string "${key}.bus.sasl.region=${AWS_REGION}" --set-string "${key}.secrets.prefix=${CLUSTER_NAME}/platform/databridge/"
          --set-string "${key}.benthos.image=$(docker_registry_with_prefix "${ecr_registry}")/redpandadata/connect:$(mirrored_image_tag redpandadata/connect)")
        ;;
      connect)
        extra+=(--set-string "${key}.secrets.prefix=${CLUSTER_NAME}/platform/connect/" --set-string "${key}.email.region=${AWS_REGION}" --set-string "${key}.notify.bus.sasl.region=${AWS_REGION}")
        if [[ -n "$(get_metadata "ses_domain")" ]]; then
          extra+=(--set-string "${key}.email.defaultFrom=notifications@$(get_metadata "ses_domain")")
        elif [[ -n "$(get_metadata "ses_existing_arn")" ]]; then
          extra+=(--set-string "${key}.email.defaultFrom=$(get_metadata "ses_from")" --set-string "${key}.email.region=$(get_metadata "ses_existing_arn" | cut -d: -f4)")
        fi
        ;;
      portico) extra+=(--set-string "${key}.internalApi.url=http://straiker-frontend-service.${INFRA_NAMESPACE}.svc.cluster.local") ;;
      grid)
        extra+=(--set-string "${key}.registryBaseURL=http://registry.${INFRA_NAMESPACE}.svc.cluster.local:80")
        # ClickHouse as replicas + Keeper: grid's migrations must create Replicated* tables (init container rewrite).
        extra+=(--set "${key}.migrations.replicatedEngines=$(clickhouse_replicated)")
        extra+=(--set-string "${key}.artifacts.bucket=$(get_metadata "grid_artifacts_bucket")" --set-string "${key}.artifacts.region=${AWS_REGION}")
        ;;
    esac
    # HA: 2 replicas spread over zones (these four charts expose replicas and topologySpread under straiker.<svc>; connect and
    # databridge group their replicas per component and stay at 1).
    case "${svc}" in
      foundation | grid | portico | registry)
        if ha_enabled; then
          extra+=(--set "${key}.replicas=2" --set "${key}.topologySpread.enabled=true"
            --set-string "${key}.topologySpread.whenUnsatisfiable=ScheduleAnyway" --set "${key}.topologySpread.minDomains=null")
        fi
        ;;
    esac
    log "Installing platform service '${svc}' (${tag})..."
    # The platform charts carry no config checksum: a config-only change (ConfigMap <svc>-config) does not restart the
    # pods, which keep the old environment. Compare it around the upgrade and restart when it changed.
    # No ConfigMap before (first install): nothing runs with an old config, so there is nothing to restart. The read must not abort
    # the installer either (set -e / pipefail: a missing ConfigMap makes the pipeline fail).
    local cfg_before="" cfg_after=""
    if kubectl get configmap "${svc}-config" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
      cfg_before="$(kubectl get configmap "${svc}-config" -n "${INFRA_NAMESPACE}" -o jsonpath='{.data}' 2>/dev/null | shasum | cut -c1-12 || true)"
    fi
    helm upgrade --install "${svc}" "${chart}" \
      --namespace "${INFRA_NAMESPACE}" --wait --timeout 15m \
      -f "${chart}/values-onprem.yaml" \
      --set-string "${key}.image.registry=$(docker_registry_with_prefix "${ecr_registry}")/straiker" \
      --set-string "${key}.image.version=${tag}" \
      --set-string "${key}.migrations.image.registry=$(docker_registry_with_prefix "${ecr_registry}")/straiker" \
      --set-string "${key}.migrations.image.version=${tag}" \
      --set "${key}.observability.otel.requireSecret=false" \
      ${extra[@]+"${extra[@]}"}
    cfg_after="$(kubectl get configmap "${svc}-config" -n "${INFRA_NAMESPACE}" -o jsonpath='{.data}' 2>/dev/null | shasum | cut -c1-12 || true)"
    if [[ -n "${cfg_before}" && "${cfg_before}" != "${cfg_after}" ]] && kubectl get deploy "${svc}-deployment" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
      log "Configuration of '${svc}' changed: restarting it."
      kubectl rollout restart "deploy/${svc}-deployment" -n "${INFRA_NAMESPACE}" >/dev/null
      kubectl rollout status "deploy/${svc}-deployment" -n "${INFRA_NAMESPACE}" --timeout=10m >/dev/null \
        || { mark_phase_blocked "'${svc}' did not become ready after its configuration changed."; return; }
    fi
  done
  apply_ha_pdbs "${INFRA_NAMESPACE}" foundation-deployment grid-deployment portico-deployment registry-deployment api-gateway api-gateway-deployment
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

# Argus v3's Secrets Manager bundle <cluster>/argus/v3: Terraform generates SYS__INFERENCE_API_KEY; the two service keys must
# EQUAL the ones the gateway and platform already hold, so they are copied here (never regenerated) and only when different.
ensure_argus_v3_secret() {
  local name="${CLUSTER_NAME}/${ARGUS_V3_SECRET}" gw platform bundle merged
  gw="$(aws secretsmanager get-secret-value --secret-id "${CLUSTER_NAME}/platform/api-gateway" --region "${AWS_REGION}" --query SecretString --output text 2>/dev/null || true)"
  platform="$(aws secretsmanager get-secret-value --secret-id "${CLUSTER_NAME}/platform/keys" --region "${AWS_REGION}" --query SecretString --output text 2>/dev/null || true)"
  bundle="$(aws secretsmanager get-secret-value --secret-id "${name}" --region "${AWS_REGION}" --query SecretString --output text 2>/dev/null || true)"
  if [[ -z "${gw}" || -z "${platform}" || -z "${bundle}" ]]; then
    mark_phase_blocked "Cannot fill ${name}: ${CLUSTER_NAME}/platform/api-gateway, ${CLUSTER_NAME}/platform/keys and ${name} must exist (run phase aws-data first)."
    return 1
  fi
  merged="$(GW="${gw}" PLATFORM="${platform}" BUNDLE="${bundle}" python3 - <<'PY'
import json, os, sys
gw, platform, bundle = (json.loads(os.environ[k]) for k in ("GW", "PLATFORM", "BUNDLE"))
want = {
    "SYS__ARGUS_INTERNAL_S2S_KEY": gw.get("SYS__ARGUS_INTERNAL_S2S_KEY", ""),
    "SYS__PLATFORM_INTERNAL_S2S_API_KEY": platform.get("PLATFORM_INTERNAL_S2S_API_KEY", ""),
}
missing = [k for k, v in want.items() if not v]
if missing:
    print("MISSING:" + ",".join(missing)); sys.exit(0)
merged = {**bundle, **want}
print("SAME" if merged == bundle else json.dumps(merged))
PY
)"
  case "${merged}" in
    MISSING:*)
      mark_phase_blocked "Cannot fill ${name}: ${merged#MISSING:} not found in the source secrets."
      return 1
      ;;
    SAME) return 0 ;;
  esac
  aws secretsmanager put-secret-value --secret-id "${name}" --region "${AWS_REGION}" --secret-string "${merged}" >/dev/null || return 1
  log "Filled ${name} with the gateway and platform service keys."
}

# $1=plaintext password. Prints its bcrypt hash (cost 10) on stdout — dex's
# staticPasswords entries require bcrypt, which openssl can't produce.
# htpasswd emits "$2y$" (Apache's bcrypt variant marker); dex's bcrypt
# library (golang.org/x/crypto/bcrypt) decodes "$2y$" identically to
# "$2a$"/"$2b$", so this verifies correctly against dex without translation.
# Password goes over stdin (-i), never as a command-line argument, so it
# doesn't show up in this machine's process listing.
bcrypt_hash() {
  local password=$1
  printf '%s' "${password}" | htpasswd -inBC 10 admin | cut -d: -f2
}

# Removes one key from the shared secret without touching others.
delete_shared_secret_key() {
  local key=$1
  if ! secret_key_exists "${key}"; then
    return
  fi
  local patch_json
  patch_json="$(python3 -c 'import json,sys; print(json.dumps({"data": {sys.argv[1]: None}}))' "${key}")"
  kubectl patch secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" --type=merge -p "${patch_json}" >/dev/null
}

# Writes whichever provider-specific keys AI_PROVIDER_MODE needs into
# straiker-secrets, using values capture_install_config already collected
# interactively. Only relevant when 'ascend' is selected. Runs after
# shared-secrets and before straiker-core/straiker-ascend, since bifrost/
# ascend's pods only read secretKeyRef env vars at container start — if
# you're re-running this after already deploying either release, roll the
# affected workloads afterward:
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
      # Preflight: verify bedrock:InvokeModel is actually usable for both
      # models Ascend is pinned to, before bifrost/straiker-ascend even
      # deploy. Confirmed live: an AWS Organizations SCP explicit deny on
      # bedrock:InvokeModel (account-wide, layered on top of an IAM role that
      # correctly allows it) surfaces identically to "model access not yet
      # granted under Bedrock > Model access" — both show up as a 403
      # AccessDeniedException, but only once a live probe run actually hits
      # it, hours into the install. An SCP applies to every principal in the
      # account, not just bifrost's own Pod-Identity role, so testing with
      # the installer's own already-authenticated credentials is an accurate
      # proxy without needing to reach into the cluster.
      require_command aws
      local bedrock_region bedrock_inference_profile model preflight_err bedrock_preflight_failed=false
      bedrock_region="$(get_metadata "bedrock_region")"
      # Pre-existing installs from before bedrock_inference_profile existed
      # have this metadata key unset - "global" matches their actual
      # long-standing behavior (the prefix used to be hardcoded to it).
      bedrock_inference_profile="$(get_metadata "bedrock_inference_profile")"
      bedrock_inference_profile="${bedrock_inference_profile:-global}"
      for model in "anthropic.claude-haiku-4-5-20251001-v1:0" "anthropic.claude-sonnet-4-6"; do
        if ! preflight_err="$(aws bedrock-runtime invoke-model \
          --region "${bedrock_region}" \
          --model-id "${bedrock_inference_profile}.${model}" \
          --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
          --cli-binary-format raw-in-base64-out \
          /dev/null 2>&1)"; then
          bedrock_preflight_failed=true
          echo "  [!] bedrock:InvokeModel preflight failed for '${bedrock_inference_profile}.${model}':" >&2
          echo "      ${preflight_err}" >&2
        fi
      done
      if [[ "${bedrock_preflight_failed}" == true ]]; then
        mark_phase_blocked "Bedrock preflight failed (see above) — either an AWS Organizations SCP is denying bedrock:InvokeModel for this account, one/both pinned models (anthropic.claude-haiku-4-5-20251001-v1:0, anthropic.claude-sonnet-4-6) haven't been granted access under Bedrock > Model access in the AWS Console for region '${bedrock_region}', or (if inference profile '${bedrock_inference_profile}' isn't 'global') that profile family has no endpoint for one of these models. Fix in AWS (or re-run with --ai-provider-mode bedrock to pick a different profile), then re-run this phase (--phase ai-provider-secrets --rerun-phase)."
        return
      fi
      log "Bedrock preflight OK: bedrock:InvokeModel confirmed usable for both pinned models via the '${bedrock_inference_profile}' profile in '${bedrock_region}'."

      # Pod Identity handles auth — no static keys needed. Ensure the bifrost
      # ServiceAccount exists (chart creates it on helm upgrade, but this phase
      # runs before straiker-core) so the Pod Identity association Terraform
      # already created has something to bind to.
      delete_shared_secret_key "SYS__OPENAI_API_KEY"
      delete_shared_secret_key "SYS__ANTHROPIC_API_KEY"
      delete_shared_secret_key "SYS__XAI_API_KEY"
      delete_shared_secret_key "BIFROST_API_KEY"
      kubectl create serviceaccount "${BIFROST_SERVICE_ACCOUNT}" \
        -n "${INFRA_NAMESPACE}" --dry-run=client -o yaml \
        | kubectl apply -f - >/dev/null
      kubectl annotate serviceaccount "${BIFROST_SERVICE_ACCOUNT}" -n "${INFRA_NAMESPACE}" \
        "meta.helm.sh/release-name=straiker-core" \
        "meta.helm.sh/release-namespace=${INFRA_NAMESPACE}" \
        --overwrite >/dev/null
      kubectl label serviceaccount "${BIFROST_SERVICE_ACCOUNT}" -n "${INFRA_NAMESPACE}" \
        "app.kubernetes.io/managed-by=Helm" \
        --overwrite >/dev/null
      log "Bedrock mode: cleared non-bedrock provider keys and prepared ServiceAccount '${BIFROST_SERVICE_ACCOUNT}' for Pod Identity."
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

# $1=subdomain (e.g. "straiker"). Returns "<subdomain>.<CUSTOM_ORIGIN_DOMAIN>"
# — only meaningful when EDGE_TYPE=none/alb/xalb/tailscale and a domain was
# actually captured; callers check that themselves before using this.
custom_domain_hostname() {
  local subdomain=$1
  local domain
  domain="$(get_metadata "custom_domain")"
  printf '%s.%s' "${subdomain}" "${domain}"
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
    helm upgrade --install "${APP_RELEASE}" "$(chart_ref "${APP_CHART_NAME}")"
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

  # straiker-frontend is a subchart of straiker-core — overriding its values
  # from the parent release needs the "<subchart-name>." prefix (unlike
  # global.* above); a bare "frontend.internalApiKey...=" would silently
  # create an unused top-level key instead.
  cmd+=(--set "straiker-frontend.frontend.internalApiKey.secretName=${SHARED_SECRETS_NAME}")
  cmd+=(--set "straiker-frontend.frontend.internalApiKey.secretKey=INTERNAL_API_KEY")

  # dex's staticPasswords hash has to be baked into its rendered ConfigMap
  # (there's no secretKeyRef-style indirection for a value embedded inside a
  # ConfigMap's config.yaml blob) — generated once by phase_shared_secrets,
  # read back out of the shared secret here. Only the hash crosses into
  # `helm get values`/release history, never the plaintext.
  local bootstrap_password_hash
  bootstrap_password_hash="$(kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.BOOTSTRAP_ADMIN_PASSWORD_HASH}' 2>/dev/null | base64 -d || true)"
  if [[ -z "${bootstrap_password_hash}" ]]; then
    mark_phase_blocked "Missing BOOTSTRAP_ADMIN_PASSWORD_HASH in '${SHARED_SECRETS_NAME}' — fix and re-run 'shared-secrets' first (--phase shared-secrets --rerun-phase)."
    return
  fi
  cmd+=(--set-string "straiker-frontend.dex.staticAdminPasswordHash=${bootstrap_password_hash}")

  # Unconditional — straiker-defend is always installed now (see
  # phase_straiker_defend), regardless of product selection.
  cmd+=(--set "straiker-frontend.frontend.argusEndpoint=http://${DEFEND_RELEASE}.${INFRA_NAMESPACE}.svc.cluster.local")
  # The platform API gateway (phase platform-services) and the flags that switch the console to it. Frontends older than
  # the FEATURE_FLAG_OVERRIDES change ignore the flags; PUBLIC_API_GATEWAY is read by every build.
  if [[ " ${PLATFORM_SERVICES} " == *" api-gateway "* ]]; then
    cmd+=(--set-string "straiker-frontend.frontend.apiGatewayUrl=http://api-gateway.${INFRA_NAMESPACE}.svc.cluster.local:443")
    # The platform-API views send the console's session to the gateway as the bearer token: on only when the gateway
    # accepts it (gateway_accepts_console_session); otherwise sign-in would end in a 401 and the old Defend page stays.
    if gateway_accepts_console_session; then
      cmd+=(--set "straiker-frontend.frontend.featureFlags.defend-platform-api-overview=true")
      # Controls reads its catalog from Argus v3 (registry -> gateway -> /internal/argus/v3): only with the v3 engine.
      cmd+=(--set "straiker-frontend.frontend.featureFlags.control-policies=$([[ "${DEFEND_ENGINE}" == "v3" ]] && echo true || echo false)")
    else
      cmd+=(--set "straiker-frontend.frontend.featureFlags.defend-platform-api-overview=false")
      cmd+=(--set "straiker-frontend.frontend.featureFlags.control-policies=false")
    fi
    # ascend-only hides Defend: on only when Ascend is the sole product.
    if [[ ",${PRODUCTS_OPT}," == *",defend,"* ]]; then
      cmd+=(--set "straiker-frontend.frontend.featureFlags.ascend-only=false")
    else
      cmd+=(--set "straiker-frontend.frontend.featureFlags.ascend-only=true")
    fi
  fi

  # --data-layer: frontend's platform DB is Aurora (not straiker-system's postgres). Password
  # comes from straiker-data's DSN Secret; Aurora requires TLS (the DSNs use sslmode=require).
  if [[ "${DATA_LAYER}" == "true" ]]; then
    local aurora_host
    aurora_host="$(get_metadata "aurora_endpoint")"
    if [[ -z "${aurora_host}" ]]; then
      mark_phase_blocked "No aurora_endpoint in install state. Run phase 'aws-data' first."
      return
    fi
    local os_endpoint os_secret
    os_endpoint="$(get_metadata "opensearch_endpoint")"
    os_secret="$(get_metadata "opensearch_secret_name")"
    if [[ -n "${os_endpoint}" && -n "${os_secret}" ]]; then
      ensure_opensearch_credentials_secret "${os_secret}" || return
      cmd+=(
        --set-string "straiker-frontend.frontend.opensearch.url=https://${os_endpoint}"
        --set-string "straiker-frontend.frontend.opensearch.credentialsSecret=opensearch-credentials"
      )
    fi
    if [[ "$(get_metadata "saas_frontend")" == "true" ]]; then
      cmd+=(
        --set "straiker-frontend.frontend.serviceAccount.create=true"
        --set-string "straiker-frontend.frontend.saasBackends.region=${AWS_REGION}"
        --set-string "straiker-frontend.frontend.saasBackends.dynamodbTable=$(get_metadata "saas_dynamodb_table_name")"
        --set-string "straiker-frontend.frontend.saasBackends.dynamodbGuardrailsTable=$(get_metadata "saas_dynamodb_guardrails_table_name")"
        --set-string "straiker-frontend.frontend.saasBackends.auditLogsStream=$(get_metadata "saas_audit_logs_stream")"
      )
    fi
    local cg_secret cg_email
    cg_secret="$(get_metadata "cognito_secret_name")"
    if [[ -n "${cg_secret}" ]]; then
      cg_email="${ADMIN_EMAIL:-$(get_metadata "admin_email")}"
      if [[ -z "${cg_email}" ]]; then
        mark_phase_blocked "Cognito is the login: pass --admin-email <address> (the first admin; remembered in install state)."
        return
      fi
      set_metadata "admin_email" "${cg_email}"
      ensure_cognito_oidc_secret "${cg_secret}" || return
      ensure_cognito_admin_user "${cg_email}" || return
      cmd+=(
        --set "straiker-frontend.dex.enabled=false"
        --set-string "straiker-frontend.frontend.oidc.issuer=$(get_metadata "cognito_issuer")"
        --set-string "straiker-frontend.frontend.oidc.clientId=$(get_metadata "cognito_client_id")"
        --set-string "straiker-frontend.frontend.oidc.clientSecretSecret.name=cognito-oidc"
        --set-string "straiker-frontend.frontend.oidc.displayName=Sign in"
        --set-string "straiker-frontend.frontend.oidc.emailIdp=COGNITO"
        --set-string "straiker-frontend.frontend.bootstrap.adminEmail=${cg_email}"
        --set-string "straiker-frontend.frontend.bootstrap.disablePasswordLogin=true"
      )
      # "Sign in with SSO": the customer's provider (federated into the pool). Its users are created as viewers on
      # first sign-in, limited to the allowed email domains plus the first admin's own domain.
      local sso_name sso_domains
      sso_name="$(get_metadata "sso_name")"
      if [[ -n "${sso_name}" ]]; then
        sso_domains="$(get_metadata "sso_domains"),${cg_email#*@}"
        cmd+=(
          --set-string "straiker-frontend.frontend.oidc.ssoIdp=${sso_name}"
          --set "straiker-frontend.frontend.oidc.autoProvision=true"
          --set-string "straiker-frontend.frontend.oidc.defaultRole=viewer"
          --set-string "straiker-frontend.frontend.oidc.allowedDomains=${sso_domains//,/\\,}"
        )
      else
        cmd+=(--set "straiker-frontend.frontend.oidc.autoProvision=false")
      fi
    fi
    ensure_synced_secret frontend-session-source "${CLUSTER_NAME}/frontend/auth" straiker-frontend-auth "%s" \
      "SESSION_SIGNING_KEY" || return
    cmd+=(--set-string "straiker-frontend.sessionKeySecret=frontend-session-source")
    cmd+=(
      --set-string "straiker-frontend.frontend.db.host=${aurora_host}"
      --set "straiker-frontend.frontend.db.port=$(get_metadata "aurora_port")"
      --set "straiker-frontend.frontend.db.sslMode=require"
      --set "straiker-frontend.frontend.db.rdsCaBundle=true"
      --set "straiker-frontend.frontend.db.passwordSecret.name=straiker-db-dsn"
      --set "straiker-frontend.frontend.db.name=frontend"
      --set "straiker-frontend.frontend.db.user=frontend"
      --set "straiker-frontend.frontend.db.passwordSecret.key=PASSWORD_frontend"
    )
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

  # EDGE_TYPE=none/alb/xalb/tailscale + a captured CUSTOM_ORIGIN_DOMAIN:
  # frontend.origin/irisControlPlanePublicEndpoint otherwise default to the
  # Caddy-style https://<subdomain>.<appDomain>:<port> formula (see
  # straiker-frontend's _helpers.tpl), which doesn't match a
  # custom-domain-served hostname — Dex's issuer + redirect-URI allowlist
  # are derived from frontend.origin, so this has to be exactly right or
  # OIDC login loops. See CUSTOM_ORIGIN_DOMAIN's declaration. Identical
  # across alb/xalb/tailscale — alb.domain/xalb.domain/tailscale.domain
  # (see phase_straiker_edge) are all the exact same value, just also
  # driving charts/straiker-edge's Ingress/Certificate instead of being left
  # for the customer's own ingress to match (EDGE_TYPE=none).
  if [[ "${EDGE_TYPE}" == "none" || "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" || "${EDGE_TYPE}" == "tailscale" ]]; then
    local custom_domain
    custom_domain="$(get_metadata "custom_domain")"
    if [[ -n "${custom_domain}" ]]; then
      cmd+=(--set "straiker-frontend.frontend.origin=https://$(custom_domain_hostname straiker)")
      if [[ ",${PRODUCTS_OPT}," == *",ascend,"* ]]; then
        cmd+=(--set "straiker-frontend.frontend.irisControlPlanePublicEndpoint=https://$(custom_domain_hostname straiker-ascend)")
      fi
    elif [[ "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" || "${EDGE_TYPE}" == "tailscale" ]]; then
      mark_phase_blocked "Missing custom_domain from install state. Re-run with --edge-type ${EDGE_TYPE} so it's captured."
      return
    fi
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
    # Pod Identity — no static keys; tell bifrost chart to skip injecting them.
    cmd+=(--set "straiker-bifrost.bedrock.podIdentity=true")
  fi

  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  "${cmd[@]}" || return
  if gateway_accepts_console_session && helm status foundation -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    ensure_platform_tenant || return
  fi
}

# The console's platform-API views read the organization's record from foundation (tenant_directory, keyed by straiker_id);
# without it the console shows "no tenant record was found for your organization". SaaS creates the record when a tenant
# is onboarded (operator API). On-prem there is one organization: the console's first customers row (getOnpremStraikerId),
# created by the console's bootstrap in this phase. Copy its id into foundation's directory (named after the customer),
# once; an existing record is left as it is. Runs in-cluster with the same postgres image as the data checks.
ensure_platform_tenant() {
  local ecr_registry registry_prefixed aurora_host pg_port name overrides result
  ecr_registry="$(get_metadata "ecr_registry")"
  registry_prefixed="$(docker_registry_with_prefix "${ecr_registry}")"
  aurora_host="$(get_metadata "aurora_endpoint")"
  pg_port="$(get_metadata "aurora_port")"
  name="${STRAIKER_CUSTOMER_NAME:-$(get_metadata "straiker_customer_name")}"
  name="${name:-Straiker}"
  # One pod: read the console's tenant id (frontend DB, frontend role), upsert it into foundation's directory (foundation
  # DSN). Values reach psql as variables (-v), never spliced into the SQL text.
  local script
  script="$(cat <<'SCRIPT'
set -e
sid=$(psql "host=$PGHOST port=$PGPORT dbname=frontend user=frontend sslmode=require" -tAc "select min(id) from customers")
[ -n "$sid" ] || { echo "NO_CUSTOMER"; exit 0; }
psql "$FOUNDATION_DATABASE_CONNECTION_STRING" -v ON_ERROR_STOP=1 -v sid="$sid" -v name="$TENANT_NAME" -tA <<"SQL"
insert into tenant_directory (straiker_id, name) values (:sid, :'name') on conflict (straiker_id) do nothing;
select setval(pg_get_serial_sequence('tenant_directory', 'straiker_id'), greatest((select max(straiker_id) from tenant_directory), 1));
select 'TENANT ' || straiker_id || ' ' || name from tenant_directory where straiker_id = :sid;
SQL
SCRIPT
)"
  overrides="$(SCRIPT="${script}" REG="${registry_prefixed}" HOST="${aurora_host}" PORT="${pg_port:-5432}" NAME="${name}" python3 -c '
import json, os
env = [
    {"name": "PGHOST", "value": os.environ["HOST"]},
    {"name": "PGPORT", "value": os.environ["PORT"]},
    {"name": "TENANT_NAME", "value": os.environ["NAME"]},
    {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": "straiker-db-dsn", "key": "PASSWORD_frontend"}}},
    {"name": "FOUNDATION_DATABASE_CONNECTION_STRING",
     "valueFrom": {"secretKeyRef": {"name": "platform-secret", "key": "FOUNDATION_DATABASE_CONNECTION_STRING"}}},
]
print(json.dumps({"spec": {"containers": [{"name": "platform-tenant", "image": os.environ["REG"] + "/library/postgres:16-alpine",
    "stdin": True, "command": ["/bin/sh", "-c", os.environ["SCRIPT"]], "env": env}]}}))')"
  kubectl delete pod platform-tenant -n "${INFRA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  result="$(kubectl run platform-tenant -n "${INFRA_NAMESPACE}" --image="${registry_prefixed}/library/postgres:16-alpine" \
    --restart=Never --rm -i --quiet --overrides="${overrides}" </dev/null 2>&1 || true)"
  if printf '%s\n' "${result}" | grep -q '^TENANT '; then
    log "Platform tenant record: $(printf '%s\n' "${result}" | grep '^TENANT ' | head -1 | cut -d' ' -f2-)"
  elif printf '%s\n' "${result}" | grep -q 'NO_CUSTOMER'; then
    log "WARNING: the console has no organization yet (customers table empty); re-run phase straiker-core after its bootstrap."
  else
    mark_phase_blocked "Could not create the platform tenant record in foundation: ${result}"
    return 1
  fi
}

# --inference-profile / --inference-mode: flag > remembered in install state > default.
inference_profile() {
  local v="${INFERENCE_PROFILE:-$(get_metadata "inference_profile")}"
  printf '%s' "${v:-production}"
}
inference_mode() {
  local v="${INFERENCE_MODE:-$(get_metadata "inference_mode")}"
  printf '%s' "${v:-vllm}"
}
# --gpu-fleet: flag > remembered > per-model for an install whose inference phase already ran (it keeps the nodes it has;
# switch it explicitly) > p4d.
gpu_fleet() {
  local v="${GPU_FLEET:-$(get_metadata "gpu_fleet")}"
  if [[ -z "${v}" && "$(get_phase_status "straiker-inference")" == "done" ]]; then
    v="per-model"
  fi
  printf '%s' "${v:-p4d}"
}
# --gpu-instance-type: flag > remembered > p4d.24xlarge. Only meaningful when gpu_fleet is "p4d" (packed).
# It may be a comma-separated list of types with the same GPU count (e.g. g6e.4xlarge,g6e.2xlarge,g6e.xlarge: capacity is per
# instance type, so Karpenter may use whichever has capacity). gpu_instance_type is the FIRST (the planning/quota/price basis,
# list the largest first); gpu_instance_types is the whole list.
gpu_instance_types() {
  local v="${GPU_INSTANCE_TYPE:-$(get_metadata "gpu_instance_type")}"
  printf '%s' "${v:-${P4D_INSTANCE_TYPE}}"
}
gpu_instance_type() {
  local v
  v="$(gpu_instance_types)"
  printf '%s' "${v%%,*}"
}
# GPU count, vCPU count, and quota family for a packed-fleet instance type. Sets GPU_SPEC_GPUS/_VCPUS/_QUOTA_CODE/_QUOTA_NAME/
# _FAMILY_RE as globals (bash 3.2 has no local-by-reference). Must stay in sync with scripts/gpu_planner.py's INSTANCE_GPUS
# (the GPU count) — both read from AWS's own published instance specs. Unknown type: caller's mark_phase_blocked, not here.
gpu_instance_spec() {
  local itype=$1
  case "${itype}" in
    p4d.24xlarge | p4de.24xlarge) GPU_SPEC_GPUS=8 GPU_SPEC_VCPUS=96 GPU_SPEC_MEM_GIB=1152 ;;
    p5.48xlarge) GPU_SPEC_GPUS=8 GPU_SPEC_VCPUS=192 GPU_SPEC_MEM_GIB=2048 ;;
    g6e.xlarge) GPU_SPEC_GPUS=1 GPU_SPEC_VCPUS=4 GPU_SPEC_MEM_GIB=32 ;;
    g6e.2xlarge) GPU_SPEC_GPUS=1 GPU_SPEC_VCPUS=8 GPU_SPEC_MEM_GIB=64 ;;
    g6e.4xlarge) GPU_SPEC_GPUS=1 GPU_SPEC_VCPUS=16 GPU_SPEC_MEM_GIB=128 ;; # one L40S per node: 10 nodes for the fleet, far easier to get than a 12xlarge
    g6e.12xlarge) GPU_SPEC_GPUS=4 GPU_SPEC_VCPUS=48 GPU_SPEC_MEM_GIB=384 ;;
    g6e.48xlarge) GPU_SPEC_GPUS=8 GPU_SPEC_VCPUS=192 GPU_SPEC_MEM_GIB=1536 ;;
    g5.48xlarge | g6.48xlarge) GPU_SPEC_GPUS=8 GPU_SPEC_VCPUS=192 GPU_SPEC_MEM_GIB=768 ;;
    *) return 1 ;;
  esac
  case "${itype}" in
    p4d.* | p4de.* | p5.*) GPU_SPEC_QUOTA_CODE="${P_VCPU_QUOTA_CODE}" GPU_SPEC_QUOTA_NAME="Running On-Demand P instances" GPU_SPEC_FAMILY_RE='^p[0-9]' ;;
    *) GPU_SPEC_QUOTA_CODE="${GPU_VCPU_QUOTA_CODE}" GPU_SPEC_QUOTA_NAME="Running On-Demand G and VT instances" GPU_SPEC_FAMILY_RE='^(g|vt)[0-9]' ;;
  esac
}
# Per-pod CPU/memory requests that fit EVERY type in --gpu-instance-type. The chart asks 8 vCPU / 32 GiB per model server, which
# a g6e.xlarge (4 vCPU, 32 GiB) or g6e.2xlarge (8 vCPU, minus system daemons) can never offer: Karpenter would silently skip those
# sizes. So size the request to the smallest listed type (one server per GPU: node vCPU minus 1 for the node's daemons, memory at
# 75%), and only ever LOWER the chart's value. Prints "cpu mem" (e.g. "3 24") or nothing when no lowering is needed.
gpu_pod_requests_for_types() {
  local t min_cpu=999 min_mem=99999 c m
  for t in $(gpu_instance_types | tr ',' ' '); do
    gpu_instance_spec "${t}" || continue
    c=$(( (GPU_SPEC_VCPUS - 1) / GPU_SPEC_GPUS ))
    m=$(( GPU_SPEC_MEM_GIB * 3 / 4 / GPU_SPEC_GPUS ))
    (( c < min_cpu )) && min_cpu=${c}
    (( m < min_mem )) && min_mem=${m}
  done
  (( min_cpu < 8 || min_mem < 32 )) || return 0
  (( min_cpu < 8 )) || min_cpu=8
  (( min_mem < 32 )) || min_mem=32
  echo "${min_cpu} ${min_mem}"
}
# charts/straiker-inference's gpuProfiles key for a packed-fleet instance type (its nodeSelector is keyed by EC2
# instance-family, not type): p4d.24xlarge's own "p4d" profile is tuned for it (A100 40GB, bf16, 32768 context); the
# others map to the closest existing profile (reasonable, not individually tuned) until the chart gets one of its own.
gpu_chart_profile_for_instance_type() {
  case "$1" in
    p4d.* | p4de.* | p5.*) printf 'p4d' ;;
    g6e.*) printf 'g6e' ;;
    g5.*) printf 'g5' ;;
    g6.*) printf 'l4' ;; # matches the chart's existing g6->L4 mapping (GKE's accelerator label never matches an EKS node)
    *) printf 'p4d' ;;
  esac
}
# GPU nodes the packed fleet needs for N model servers (one per GPU), on the resolved instance type.
p4d_nodes_for() {
  gpu_instance_spec "$(gpu_instance_type)" || { echo 0; return 1; }
  printf '%s' $(( ($1 + GPU_SPEC_GPUS - 1) / GPU_SPEC_GPUS ))
}

remember_inference_settings() {
  local profile mode
  profile="$(inference_profile)"
  mode="$(inference_mode)"
  case "${profile}" in production | test) ;; *)
    echo "ERROR: --inference-profile must be 'production' or 'test', got '${profile}'." >&2
    return 1
    ;;
  esac
  case "${mode}" in vllm | bedrock) ;; *)
    echo "ERROR: --inference-mode must be 'vllm' or 'bedrock', got '${mode}'." >&2
    return 1
    ;;
  esac
  if [[ -n "${INFERENCE_MODELS}" ]]; then
    local wanted known m
    known=" $(PRODUCTS_OPT="${PRODUCTS_OPT}" INFERENCE_MODELS="" inference_models_for_products | tr '\n' ' ')"
    for m in ${INFERENCE_MODELS//,/ }; do
      if [[ "${known}" != *" ${m} "* ]]; then
        echo "ERROR: --inference-models: '${m}' is not a model of the selected products (valid:${known})." >&2
        return 1
      fi
    done
    log "WARNING: --inference-models ${INFERENCE_MODELS}: only part of the fleet is deployed. For testing, never for a customer."
  fi
  local fleet max_nodes crs itype
  fleet="$(gpu_fleet)"
  max_nodes="${GPU_MAX_NODES:-$(get_metadata "gpu_max_nodes")}"
  max_nodes="${max_nodes:-4}"
  crs="${GPU_CAPACITY_RESERVATION:-$(get_metadata "gpu_capacity_reservation")}"
  itype="$(gpu_instance_type)"
  local itypes
  itypes="$(gpu_instance_types)"
  case "${fleet}" in p4d | per-model) ;; *)
    echo "ERROR: --gpu-fleet must be 'p4d' or 'per-model', got '${fleet}'." >&2
    return 1
    ;;
  esac
  if [[ ! "${max_nodes}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --gpu-max-nodes must be a positive whole number, got '${max_nodes}'." >&2
    return 1
  fi
  if [[ -n "${crs}" && ! "${crs}" =~ ^cr-[0-9a-f]+(,cr-[0-9a-f]+)*$ ]]; then
    echo "ERROR: --gpu-capacity-reservation takes cr-... ids, comma-separated, got '${crs}'." >&2
    return 1
  fi
  if [[ "${fleet}" == "p4d" ]] && ! gpu_instance_spec "${itype}"; then
    echo "ERROR: --gpu-instance-type '${itype}' is not a known packed-fleet type (p4d.24xlarge, p4de.24xlarge, p5.48xlarge, g6e.xlarge, g6e.2xlarge, g6e.4xlarge, g6e.12xlarge, g6e.48xlarge, g5.48xlarge, g6.48xlarge)." >&2
    return 1
  fi
  if [[ "${fleet}" == "p4d" && "${itypes}" == *,* ]]; then
    local t first_gpus
    gpu_instance_spec "${itype}"; first_gpus=${GPU_SPEC_GPUS}
    for t in ${itypes//,/ }; do
      if ! gpu_instance_spec "${t}" || [[ ${GPU_SPEC_GPUS} -ne ${first_gpus} ]]; then
        echo "ERROR: --gpu-instance-type list '${itypes}': '${t}' is unknown or has a different GPU count than '${itype}' (all must have ${first_gpus} GPU(s); list the largest first)." >&2
        return 1
      fi
    done
    gpu_instance_spec "${itype}"
    local fam
    for t in ${itypes//,/ }; do
      [[ -z "${fam:-}" || "${t%%.*}" == "${fam}" ]] || { echo "ERROR: --gpu-instance-type list '${itypes}' mixes GPU families ('${fam}' and '${t%%.*}'). The model servers are pinned to the first type's family (their GPU tier settings differ), so only sizes of ONE family can be used together, e.g. g6e.4xlarge,g6e.2xlarge,g6e.xlarge." >&2; return 1; }
      fam="${t%%.*}"
    done
  fi
  if [[ "${fleet}" == "p4d" ]] && gpu_instance_spec "${itype}"; then
    # The pool's GPU limit is max-nodes x GPUs per node. It must cover the fleet with room to double it (replicas, upgrades), or
    # pods wait forever on a limit nobody sees: 4 single-GPU nodes would cap 10 model servers at 4 GPUs.
    local fleet_servers=0 fleet_line min_nodes
    while IFS= read -r fleet_line; do [[ -n "${fleet_line}" ]] && fleet_servers=$((fleet_servers + 2)); done < <(inference_models_for_products)
    min_nodes=$(( (fleet_servers * 2 + GPU_SPEC_GPUS - 1) / GPU_SPEC_GPUS ))
    if [[ ${fleet_servers} -gt 0 && ${max_nodes} -lt ${min_nodes} ]]; then
      log "--gpu-max-nodes ${max_nodes} x ${GPU_SPEC_GPUS} GPU(s) per ${itype} node is too small for ${fleet_servers} model servers: using ${min_nodes} (room to double the fleet)."
      max_nodes="${min_nodes}"
    fi
  fi
  set_metadata "gpu_fleet" "${fleet}"
  set_metadata "gpu_instance_type" "${itypes}"
  set_metadata "gpu_max_nodes" "${max_nodes}"
  set_metadata "gpu_capacity_reservation" "${crs}"
  set_metadata "inference_profile" "${profile}"
  set_metadata "inference_mode" "${mode}"
  if [[ "${profile}" == "test" ]]; then
    log "WARNING: --inference-profile test: model servers may share GPUs and thanos may be quantized. This is for small test clusters only, never for a customer."
  fi
  if [[ "${mode}" == "bedrock" ]]; then
    log "Inference mode bedrock: no GPU model fleet is deployed (Argus v3's vision/wanda/Kev controls and Ascend's thanos are unavailable)."
  fi
}

# The G/VT vCPU quota gates how many GPU nodes Karpenter can start: too low and servers sit Pending forever, so say so up front.
check_gpu_vcpu_quota() {
  local nodes=$1 needed quota used available quota_code quota_name family_re node_vcpus request
  [[ "${CLOUD_PROVIDER}" == "gke" ]] && return 0
  if [[ "$(gpu_fleet)" == "p4d" ]]; then
    gpu_instance_spec "$(gpu_instance_type)" || { mark_phase_blocked "Unknown --gpu-instance-type '$(gpu_instance_type)'."; return 1; }
    quota_code="${GPU_SPEC_QUOTA_CODE}" quota_name="${GPU_SPEC_QUOTA_NAME}" family_re="${GPU_SPEC_FAMILY_RE}" node_vcpus=${GPU_SPEC_VCPUS}
    local max_nodes
    max_nodes="$(get_metadata "gpu_max_nodes")"
    request=$(( ${max_nodes:-4} * GPU_SPEC_VCPUS ))
  else
    quota_code="${GPU_VCPU_QUOTA_CODE}" quota_name="Running On-Demand G and VT instances" family_re='^(g|vt)[0-9]' node_vcpus=${GPU_NODE_VCPUS}
    request=512
  fi
  needed=$((nodes * node_vcpus))
  if ! quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code "${quota_code}" \
      --region "${AWS_REGION}" --query 'Quota.Value' --output text 2>/dev/null)"; then
    log "WARNING: could not read the EC2 '${quota_name}' quota; ${needed} vCPUs are needed for ${nodes} GPU nodes."
    return 0
  fi
  # The quota counts every instance of those families already running in the account (older model nodes, other teams).
  used="$(aws ec2 describe-instances --region "${AWS_REGION}" --filters Name=instance-state-name,Values=pending,running \
    --query 'Reservations[].Instances[].[InstanceType,CpuOptions.CoreCount,CpuOptions.ThreadsPerCore]' --output text 2>/dev/null \
    | awk -v re="${family_re}" '$1 ~ re { n += $2 * $3 } END { print n + 0 }')"
  available="$(awk -v q="${quota}" -v u="${used:-0}" 'BEGIN { printf "%d", q - u }')"
  if [[ "${available}" -lt "${needed}" && -n "${INFERENCE_MODELS}" ]]; then
    # --inference-models is the deliberate partial test: servers that do not fit simply wait (Pending) for quota.
    log "WARNING: EC2 '${quota_name}' quota leaves ${available} of the ${needed} vCPUs the missing GPU nodes need (${used:-0} of ${quota} in use); those servers will stay Pending until the quota is raised."
    INFERENCE_NO_WAIT=true # helm must not wait for pods that cannot get a node
    return 0
  fi
  if [[ "${available}" -lt "${needed}" ]]; then
    mark_phase_blocked "EC2 quota '${quota_name}' is ${quota} vCPUs in ${AWS_REGION} and ${used:-0} are already in use, leaving ${available}; ${nodes} GPU nodes need ${needed}. Remove GPU nodes you no longer need or request an increase to ${request} vCPUs (Service Quotas, code ${quota_code}: aws service-quotas request-service-quota-increase --service-code ec2 --quota-code ${quota_code} --desired-value ${request} --region ${AWS_REGION}), then re-run this phase."
    return 1
  fi
  log "EC2 '${quota_name}' quota OK: ${available} vCPUs free of ${quota} (${used:-0} in use), ${needed} needed for ${nodes} GPU nodes."
  if [[ "$(gpu_fleet)" == "p4d" ]] && awk -v a="${available}" -v r="${request}" -v u="${used:-0}" 'BEGIN { exit !(a + u < r) }'; then
    log "WARNING: the '${quota_name}' quota (${quota} vCPUs) does not cover the pool's maximum of $(( request / node_vcpus )) $(gpu_instance_type) nodes (${request} vCPUs): the fleet runs, but cannot scale that far. Request ${request} (code ${quota_code})."
  fi
}

# The packed fleet's instance type (default p4d.24xlarge; see gpu_instance_type) is offered in some regions and AZs only.
# $1 = space-separated AZs the GPU nodes may use (empty = any AZ of the region). Blocks when none of them offers it.
check_p4d_offered() {
  local azs=$1 itype offered match="" az
  itype="$(gpu_instance_type)"
  offered="$(aws ec2 describe-instance-type-offerings --region "${AWS_REGION}" --location-type availability-zone \
    --filters "Name=instance-type,Values=${itype}" --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null || true)"
  if [[ -z "${offered}" || "${offered}" == "None" ]]; then
    mark_phase_blocked "${itype} is not offered in ${AWS_REGION}. Install in a region that has it, pass --gpu-instance-type for one that does, or use --gpu-fleet per-model."
    return 1
  fi
  if [[ -z "${azs}" ]]; then
    log "${itype} is offered in ${AWS_REGION}: $(printf '%s' "${offered}" | tr '\t' ' ')."
    return 0
  fi
  for az in ${azs}; do
    [[ " $(printf '%s' "${offered}" | tr '\t' ' ') " == *" ${az} "* ]] && match+="${az} "
  done
  if [[ -z "${match}" ]]; then
    mark_phase_blocked "${itype} is not offered in the AZs the GPU nodes may use (${azs}); it is offered in: $(printf '%s' "${offered}" | tr '\t' ' '). Use --provision-strategy ha (more AZs) or subnets in one of those AZs."
    return 1
  fi
  log "${itype} is offered in the GPU nodes' AZs: ${match}"
}

# High availability (--provision-strategy ha|max): services run 2 replicas spread over zones instead of the on-prem default of 1.
# The spread is soft (ScheduleAnyway): a zone with no capacity must not leave a pod Pending, but Karpenter and the scheduler still
# prefer another zone for the second replica. Under 'min' nothing changes (one zone, one replica).
ha_enabled() { [[ "${PROVISION_STRATEGY:-min}" != "min" ]]; }

# PodDisruptionBudgets (maxUnavailable 1) for the vendored platform charts, which ship none: without one, a node drain
# (Karpenter consolidation, upgrades) may evict both replicas at once. Applied with kubectl, not Helm (the charts are synced from
# another repo), and only for Deployments that run 2 or more replicas. $1 = namespace, rest = deployment names.
apply_ha_pdbs() {
  local ns=$1 d reps sel
  shift
  ha_enabled || return 0
  for d in "$@"; do
    reps="$(kubectl get deploy "${d}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    [[ "${reps:-0}" =~ ^[0-9]+$ ]] && (( reps >= 2 )) || continue
    sel="$(kubectl get deploy "${d}" -n "${ns}" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"]["selector"]["matchLabels"]))' 2>/dev/null || true)"
    [[ -n "${sel}" ]] || continue
    python3 - "${d}" "${ns}" "${sel}" <<'PYEOF' | kubectl apply -f - >/dev/null || log "WARNING: could not create the PodDisruptionBudget for ${d}."
import json, sys
name, ns, sel = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
print(json.dumps({"apiVersion": "policy/v1", "kind": "PodDisruptionBudget",
  "metadata": {"name": name + "-pdb", "namespace": ns, "labels": {"app.kubernetes.io/managed-by": "straiker-installer"}},
  "spec": {"maxUnavailable": 1, "selector": {"matchLabels": sel}}}))
PYEOF
  done
}

# The AZs GPU nodes will launch in, when the user chose them (empty = not chosen: any AZ of the region). --provision-strategy
# min confines nodes to the first one.
gpu_node_azs() {
  [[ -n "${AVAILABILITY_ZONES_OPT}" && -z "${VPC_ID}" ]] || return 0
  local azs
  azs="$(resolve_availability_zones 2 2>/dev/null)" || return 0
  if [[ "${PROVISION_STRATEGY}" == "min" ]]; then echo "${azs%% *}"; else echo "${azs}"; fi
}

# Capacity Blocks for ML (p4d/p5) a customer could BUY for this fleet, printed in the first phase when no reservation is given.
# Information only: it never blocks (it says nothing about on-demand capacity). Needs ec2:DescribeCapacityBlockOfferings.
show_capacity_block_offerings() {
  local nodes=$1 itype out
  [[ -z "${GPU_CAPACITY_RESERVATION:-$(get_metadata "gpu_capacity_reservation")}" ]] || return 0
  itype="$(gpu_instance_type)"
  case "${itype}" in p4d.* | p4de.* | p5.*) ;; *) return 0 ;; esac
  out="$(aws ec2 describe-capacity-block-offerings --region "${AWS_REGION}" --instance-type "${itype}" --instance-count "${nodes}" \
    --capacity-duration-hours 24 --output json 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 0
  printf '%s' "${out}" | python3 -c '
import json, sys
try:
    offers = json.load(sys.stdin).get("CapacityBlockOfferings", [])
except Exception:
    sys.exit(0)
itype, nodes = sys.argv[1], sys.argv[2]
if not offers:
    print("No reservation was given and AWS lists no Capacity Block for %s x %s (24 h) right now. On-demand capacity is not guaranteed; reserve capacity before a customer install." % (nodes, itype))
    sys.exit(0)
offers.sort(key=lambda o: o.get("StartDate", ""))
print("No reservation was given. Capacity Blocks you could buy for %s x %s (24 h), earliest first:" % (nodes, itype))
for o in offers[:3]:
    print("  %s  starts %s  upfront %s %s  (offering %s)" % (o.get("AvailabilityZone"), o.get("StartDate", "")[:16], o.get("UpfrontFee"), o.get("CurrencyCode", "USD"), o.get("CapacityBlockOfferingId")))
' "${itype}" "${nodes}" | while IFS= read -r line; do log "${line}"; done
  return 0
}

# One capacity probe launch: asks for 1 to $3 instances of type $2 (AMI $1) in subnet $4 and terminates what it got. A fleet does not
# have to launch all at once (Karpenter launches node by node and may mix types), so "all or nothing" would call a zone empty that
# can still hold most of the fleet. Sets PROBE_LAUNCHED (instances AWS gave us), PROBE_NOTE (error text) and appends the ids to
# PROBE_IDS. Returns 0 when at least one launched, 1 when AWS had no capacity, 2 on any other error.
PROBE_LAUNCHED=0
PROBE_NOTE=""
PROBE_IDS=""
probe_launch() {
  local ami=$1 itype=$2 nodes=$3 subnet=$4 out rc=0 ids
  PROBE_LAUNCHED=0
  PROBE_NOTE=""
  out="$(aws ec2 run-instances --region "${AWS_REGION}" --image-id "${ami}" --instance-type "${itype}" --count "1:${nodes}" \
    --subnet-id "${subnet}" --metadata-options HttpTokens=required --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=straiker-capacity-probe,Value=${CLUSTER_NAME}},{Key=Name,Value=straiker-capacity-probe}]" \
    --query 'Instances[].InstanceId' --output text 2>&1)" || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    ids="${out}"
    PROBE_LAUNCHED="$(echo "${ids}" | wc -w | tr -d ' ')"
    PROBE_IDS+="${ids} "
    aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids ${ids} >/dev/null 2>&1 \
      || log "WARNING: could not terminate the probe instances (${ids}); terminate them in the EC2 console."
    return 0
  fi
  if [[ "${out}" == *InsufficientInstanceCapacity* ]]; then return 1; fi
  PROBE_NOTE="${out##*: }"
  return 2
}

# Picks the zone the cluster is built in by trying the GPU fleet where it will run, BEFORE any cluster exists (so a zone with no
# capacity costs nothing and fails in minutes, not after a 15-minute build). AWS has no call that reports free on-demand capacity,
# so this launches as much of the fleet as AWS will give (1 to N nodes) in a throwaway VPC that has one subnet per candidate zone, terminates
# it, and deletes the VPC. The zone that gives the most (stopping at the first that holds the whole fleet) becomes the first AZ of the cluster (metadata gpu_first_az, read by
# resolve_availability_zones); with --provision-strategy min that is the only zone nodes run in. $1 = GPU nodes needed.
# Not run: with --availability-zones, --vpc-id, a --gpu-capacity-reservation, --skip-capacity-probe, once the cluster's AZs are
# fixed, or when a throwaway VPC cannot be created (the post-build probe still runs then). Only InsufficientInstanceCapacity
# everywhere blocks; any other error only warns.
select_gpu_zone() {
  local nodes=$1
  [[ "${SKIP_CAPACITY_PROBE}" != true && "${CLOUD_PROVIDER}" != "gke" ]] || return 0
  [[ -z "${AVAILABILITY_ZONES_OPT}" && -z "${VPC_ID}" ]] || return 0
  [[ -z "${GPU_CAPACITY_RESERVATION:-$(get_metadata "gpu_capacity_reservation")}" ]] || return 0
  [[ -z "$(get_metadata "availability_zones")" ]] || return 0 # the cluster's zones are already fixed
  local last
  last="$(get_metadata "gpu_zone_probe")"
  if [[ "${last}" == ok\|* ]]; then
    local at="${last##*|}"
    if [[ "${at}" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < 7200 )); then
      log "GPU zone probe passed less than 2 hours ago (zone $(get_metadata "gpu_first_az")): skipping."
      return 0
    fi
  fi
  local types itype az azs="" offered
  types="$(gpu_instance_types)"
  for itype in ${types//,/ }; do
    offered="$(aws ec2 describe-instance-type-offerings --region "${AWS_REGION}" --location-type availability-zone \
      --filters "Name=instance-type,Values=${itype}" --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null | tr '\t' ' ' || true)"
    for az in ${offered}; do [[ " ${azs} " == *" ${az} "* ]] || azs+="${azs:+ }${az}"; done
  done
  azs="$(echo "${azs}" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)"
  if [[ -z "${azs}" ]]; then
    log "WARNING: zone probe skipped: could not list the zones that offer ${types}."
    return 0
  fi
  if [[ "${AUTO_YES}" != true ]]; then
    local ans
    ans="$(prompt_line "Find a zone with GPU capacity now? This launches ${nodes} x ${types%%,*} for about a minute per zone (about \$1-2 for p4d, cents for g6e) in a temporary VPC and removes everything again [Y/n]: " || true)"
    case "${ans}" in n | N | no | NO) log "GPU zone probe skipped at your request."; return 0 ;; esac
  fi
  local ami
  ami="$(aws ssm get-parameter --region "${AWS_REGION}" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text 2>/dev/null || true)"
  if [[ -z "${ami}" || "${ami}" == "None" ]]; then
    log "WARNING: zone probe skipped: could not look up the Amazon Linux AMI in ${AWS_REGION}."
    return 0
  fi
  local vpc subnets="" az_subnets="" i=0 az sn
  vpc="$(aws ec2 create-vpc --region "${AWS_REGION}" --cidr-block 10.255.0.0/16 \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=straiker-capacity-probe,Value=${CLUSTER_NAME}},{Key=Name,Value=straiker-capacity-probe}]" \
    --query Vpc.VpcId --output text 2>/dev/null || true)"
  if [[ -z "${vpc}" || "${vpc}" == "None" ]]; then
    log "WARNING: zone probe skipped: could not create a temporary VPC (ec2:CreateVpc denied?). The probe after the cluster build still runs."
    return 0
  fi
  for az in ${azs}; do
    i=$((i + 1))
    sn="$(aws ec2 create-subnet --region "${AWS_REGION}" --vpc-id "${vpc}" --availability-zone "${az}" --cidr-block "10.255.${i}.0/24" \
      --query Subnet.SubnetId --output text 2>/dev/null || true)"
    if [[ -n "${sn}" && "${sn}" != "None" ]]; then
      subnets+="${sn} "
      az_subnets+="${az} ${sn}"$'\n'
    fi
  done
  local chosen="" tried="" failed="" note="" best=0 best_az="" best_type="" zone_best got
  PROBE_IDS=""
  while read -r az sn; do
    [[ -n "${az}" ]] || continue
    zone_best=0
    for itype in ${types//,/ }; do
      probe_launch "${ami}" "${itype}" "${nodes}" "${sn}" && got=0 || got=$?
      tried+="${az}/${itype} "
      if [[ ${got} -eq 0 ]]; then
        log "GPU zone probe: ${PROBE_LAUNCHED} of ${nodes} x ${itype} launched in ${az} and terminated."
        if (( PROBE_LAUNCHED > zone_best )); then zone_best=${PROBE_LAUNCHED}; fi
        if (( PROBE_LAUNCHED > best )); then best=${PROBE_LAUNCHED}; best_az="${az}"; best_type="${itype}"; fi
        (( PROBE_LAUNCHED >= nodes )) && break
      elif [[ ${got} -eq 1 ]]; then
        failed+="${az}/${itype} "
        log "GPU zone probe: no capacity for ${nodes} x ${itype} in ${az} right now."
      else
        note="${PROBE_NOTE}"
        log "WARNING: GPU zone probe could not run in ${az} for ${itype}: ${note}"
      fi
    done
    if (( zone_best >= nodes )); then break; fi # a zone that holds the whole fleet: no need to look further
  done <<< "${az_subnets}"
  chosen="${best_az}"
  probed_ids="${PROBE_IDS}"
  # Remove the throwaway VPC: wait for the probe instances to be gone first (their network interfaces block subnet deletion).
  [[ -n "${probed_ids// /}" ]] && aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids ${probed_ids} >/dev/null 2>&1 || true
  for sn in ${subnets}; do aws ec2 delete-subnet --region "${AWS_REGION}" --subnet-id "${sn}" >/dev/null 2>&1 || true; done
  local try
  for try in 1 2 3 4 5; do
    aws ec2 delete-vpc --region "${AWS_REGION}" --vpc-id "${vpc}" >/dev/null 2>&1 && break
    sleep 5
  done
  aws ec2 describe-vpcs --region "${AWS_REGION}" --vpc-ids "${vpc}" >/dev/null 2>&1 \
    && log "WARNING: could not delete the temporary probe VPC ${vpc} (tag straiker-capacity-probe=${CLUSTER_NAME}); delete it in the VPC console."
  if [[ -n "${chosen}" ]]; then
    set_metadata "gpu_first_az" "${chosen}"
    set_metadata "gpu_zone_probe" "ok|${chosen}|$(date +%s)"
    (( best < nodes )) && log "WARNING: the best zone (${chosen}) could give ${best} of the ${nodes} GPU nodes right now; the rest launch as AWS frees capacity, and the install keeps waiting for them (up to ${GPU_WAIT_HOURS:-6} hours)."
    log "The cluster will be built with ${chosen} as its first (and, with provision strategy 'min', only node) zone."
    return 0
  fi
  if [[ -z "${failed}" ]]; then
    log "WARNING: the GPU zone probe could not run (${note:-no usable zone}); continuing without it."
    return 0
  fi
  log "WARNING: no zone has capacity for ${nodes} x ${types} right now (tried: ${tried% }). Continuing: the install waits for GPU nodes (up to ${GPU_WAIT_HOURS:-6} hours), trying every instance type in --gpu-instance-type."
  return 0
}

# --gpu-capacity-reservation pre-flight: every reservation must be usable by this fleet BEFORE any cost is incurred. Checks each
# cr-... id: visible in this account/region, active (a Capacity Block not yet started is reported with its start time), the
# fleet's instance type, Linux and default tenancy, in an AZ the cluster launches nodes in, and enough free instances for $1 nodes
# (a shortfall only warns: Karpenter falls back to on-demand for the rest). Blocks on an unusable reservation.
check_gpu_reservations() {
  local nodes=$1 crs itype node_azs out rc=0 line errs="" have
  crs="${GPU_CAPACITY_RESERVATION:-$(get_metadata "gpu_capacity_reservation")}"
  [[ -n "${crs}" ]] || return 0
  [[ "$(gpu_fleet)" == "p4d" ]] || return 0
  itype="$(gpu_instance_types)"
  node_azs="$(gpu_node_azs)"
  if [[ -z "${node_azs}" ]]; then
    have="$(get_metadata "availability_zones" | tr ',' ' ' | xargs)"
    if [[ -n "${have}" ]]; then
      if [[ "${PROVISION_STRATEGY}" == "min" ]]; then node_azs="${have%% *}"; else node_azs="${have}"; fi
    fi
  fi
  out="$(aws ec2 describe-capacity-reservations --region "${AWS_REGION}" --capacity-reservation-ids ${crs//,/ } --output json 2>&1)" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    if [[ "${out}" == *InvalidCapacityReservationId* ]]; then
      mark_phase_blocked "--gpu-capacity-reservation: AWS does not know a reservation in ${AWS_REGION} / this account for '${crs}' (${out##*: }). Check the id, region and account (a Capacity Block shared from another account must be shared with this one)."
    else
      log "WARNING: could not check the capacity reservation(s) ${crs}: ${out##*: }"
      return 0
    fi
    return 1
  fi
  while IFS= read -r line; do
    case "${line}" in
      ERR:*) errs+="${line#ERR:} " ;;
      WARN:*) log "WARNING: ${line#WARN:}" ;;
      OK:*) log "${line#OK:}" ;;
    esac
  done < <(printf '%s' "${out}" | python3 -c '
import json, sys, datetime
itypes, nodes, azs = sys.argv[1].split(","), int(sys.argv[2]), sys.argv[3].split()
itype = itypes[0]
now = datetime.datetime.now(datetime.timezone.utc)
def ts(v):
    try: return datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
    except Exception: return None
total = 0
for r in json.load(sys.stdin).get("CapacityReservations", []):
    rid, st, az = r["CapacityReservationId"], r.get("State", "?"), r.get("AvailabilityZone", "?")
    bad = []
    if r.get("InstanceType") not in itypes:
        bad.append("is for %s, not %s" % (r.get("InstanceType"), " or ".join(itypes)))
    if r.get("InstancePlatform") not in ("Linux/UNIX", None):
        bad.append("is for %s (the nodes are Linux)" % r.get("InstancePlatform"))
    if r.get("Tenancy", "default") != "default":
        bad.append("has %s tenancy (must be default)" % r.get("Tenancy"))
    if azs and az not in azs:
        bad.append("is in %s but the cluster launches GPU nodes in %s; add --availability-zones %s,<another> (the first AZ is the node AZ)" % (az, " ".join(azs), az))
    if st in ("pending", "scheduled", "assessing", "delayed", "payment-pending"):
        start = ts(r.get("StartDate", "")) if r.get("StartDate") else None
        print("WARN:%s is %s%s; the GPU nodes use on-demand until it is active." % (rid, st, (" until " + start.strftime("%Y-%m-%d %H:%M UTC")) if start else ""))
    elif st != "active":
        bad.append("is %s (only active reservations can be used)" % st)
    else:
        total += int(r.get("AvailableInstanceCount", 0))
    end = ts(r.get("EndDate", "")) if r.get("EndDate") else None
    if end and (end - now).days < 7 and st == "active":
        print("WARN:%s ends %s; the nodes in it are replaced by on-demand ones after that." % (rid, end.strftime("%Y-%m-%d %H:%M UTC")))
    if r.get("InstanceMatchCriteria") == "open":
        print("WARN:%s is an open reservation: any matching instance in the account may use it first." % rid)
    if bad:
        print("ERR:Reservation %s %s." % (rid, "; ".join(bad)))
    else:
        print("OK:Reservation %s: %s %s in %s, %s of %s instances free." % (rid, st, r.get("InstanceType"), az, r.get("AvailableInstanceCount"), r.get("TotalInstanceCount")))
if total < nodes:
    print("WARN:The active reservation(s) have %d free %s instance(s) and the fleet needs %d; the other %d node(s) launch on-demand." % (total, itype, nodes, nodes - total))
' "${itype}" "${nodes}" "${node_azs}")
  if [[ -n "${errs}" ]]; then
    mark_phase_blocked "${errs}Fix the reservation or drop --gpu-capacity-reservation, then re-run."
    return 1
  fi
}

# Prerequisites check, run in the first phase (before any cluster is built). per-model: one GPU node per model server against
# the G/VT quota. p4d: 8 servers per node against the P quota. A new AWS account usually has 0-8 vCPUs of either, so the
# fleet cannot start until the customer raises it.
preflight_gpu_quota() {
  [[ "${CLOUD_PROVIDER}" == "gke" ]] && return 0
  [[ "$(inference_mode)" == "vllm" && "$(inference_profile)" == "production" ]] || return 0
  local count=0 line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && count=$((count + 1))
  done < <(inference_models_for_products)
  [[ ${count} -gt 0 ]] || return 0
  require_command aws
  if [[ "$(gpu_fleet)" == "p4d" ]]; then
    check_p4d_offered "$(gpu_node_azs)" || return 1
    check_gpu_reservations "$(p4d_nodes_for $((count * 2)))" || return 1
    show_capacity_block_offerings "$(p4d_nodes_for $((count * 2)))"
    select_gpu_zone "$(p4d_nodes_for $((count * 2)))" || return 1
    check_gpu_vcpu_quota "$(p4d_nodes_for $((count * 2)))"
  else
    check_gpu_vcpu_quota $((count * 2))
  fi
}

# Advertise each GPU N times (test profile time-slicing) by upgrading straiker-system's device plugin; 0 turns it off.
apply_gpu_time_slicing() {
  local n=$1 current chart
  current="$(get_metadata "gpu_time_slicing_replicas")"
  current="${current:-0}"
  [[ "${n}" == "${current}" ]] && return 0
  log "Setting NVIDIA device plugin time-slicing to ${n} servers per GPU (was ${current})."
  chart="$(chart_ref "${INFRA_CHART_NAME}")"
  [[ -d "${chart}" ]] && helm dependency build "${chart}" >/dev/null
  helm upgrade "${INFRA_RELEASE}" "${chart}" --namespace "${INFRA_NAMESPACE}" \
    --reset-then-reuse-values --set "nvidia.devicePlugin.timeSlicing.replicas=${n}" \
    --wait --timeout "${HELM_TIMEOUT}" >/dev/null || { mark_phase_blocked "Could not apply GPU time-slicing to release '${INFRA_RELEASE}'."; return 1; }
  kubectl -n kube-system rollout status ds/straiker-nvidia-device-plugin --timeout=300s >/dev/null 2>&1 || true
  set_metadata "gpu_time_slicing_replicas" "${n}"
}

# Fail fast on GPU capacity: `helm --wait` alone would sit for the full --timeout (15 min per batch) while Karpenter cannot get the
# GPU instances. This watcher runs next to the helm installs, reads Karpenter's launch failures for the straiker-gpu pool every
# GPU_WATCH_INTERVAL seconds and, on a verdict, writes it to $1 and stops the helm runs ($3...; they mark the release failed and
# a re-run resumes; Karpenter keeps retrying). $2 = GPU nodes the fleet needs.
#   hard    a launch failure that waiting cannot fix (quota, permissions, bad AMI/subnet/reservation), twice
#   pool    the pool's GPU limit is reached, twice
# "Insufficient capacity" never stops the wait (only the 6-hour limit does, see phase_straiker_inference); it is just reported.
classify_gpu_launch_failures() {
  python3 -c '
import json, re, sys
ice = hard = pool = 0
ICE = re.compile(r"InsufficientInstanceCapacity|UnfulfillableCapacity|insufficient capacity|ReservationCapacityExceeded|Insufficient capacity", re.I)
HARD = re.compile(r"VcpuLimitExceeded|InstanceLimitExceeded|UnauthorizedOperation|AuthFailure|InvalidAMIID|InvalidSubnet|InvalidParameter|Unsupported|OptInRequired|InvalidCapacityReservation|MaxSpotInstanceCountExceeded|InsufficientFreeAddresses")
for line in sys.stdin:
    try:
        d = json.loads(line)
        t = " ".join(str(d.get(k, "")) for k in ("error", "message"))
    except Exception:
        t = line
    if "exceed limits for nodepool" in t:
        pool += 1
    elif ICE.search(t):
        ice += 1
    elif HARD.search(t):
        hard += 1
print(ice, hard, pool)'
}

watch_gpu_capacity() {
  local verdict=$1 needed=$2; shift 2
  local interval=${GPU_WATCH_INTERVAL:-20}
  local start=${SECONDS} last_nodes=0 last_growth=${SECONDS} last_note=${SECONDS} elapsed nodes ice hard pool reason pid alive
  while :; do
    sleep "${interval}"
    alive=false
    for pid in "$@"; do kill -0 "${pid}" 2>/dev/null && alive=true; done
    ${alive} || return 0
    elapsed=$((SECONDS - start))
    read -r ice hard pool < <(kubectl -n karpenter logs deploy/karpenter --since="$((elapsed + 30))s" 2>/dev/null \
      | grep -E 'failed launching nodeclaim|exceed limits' | grep 'straiker-gpu' | classify_gpu_launch_failures || echo "0 0 0")
    nodes="$(kubectl get nodes -l karpenter.sh/nodepool=straiker-gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    nodes=${nodes:-0}
    if (( nodes > last_nodes )); then last_nodes=${nodes}; last_growth=${SECONDS}; fi
    reason=""
    if (( hard >= 2 )); then reason=hard
    elif (( pool >= 2 )); then reason=pool
    fi # capacity shortages never stop the wait: Karpenter keeps trying every listed type until the overall limit
    if [[ -n "${reason}" ]]; then
      echo "${reason}|${elapsed}|${nodes}|${needed}" > "${verdict}"
      for pid in "$@"; do pkill -TERM -P "${pid}" 2>/dev/null || true; kill -TERM "${pid}" 2>/dev/null || true; done
      return 0
    fi
    if (( SECONDS - last_note >= 120 )); then
      last_note=${SECONDS}
      if (( nodes >= needed )); then
        log "GPU capacity: all ${needed} GPU node(s) are up; waiting for the model servers to load."
      elif (( ice > 0 )); then
        log "GPU capacity: ${nodes} of ${needed} GPU node(s) up; AWS has no capacity for the rest right now (${ice} failed launches so far). Karpenter keeps retrying."
      fi
    fi
  done
}

# After model pods stay Pending, say WHY when Karpenter could not get GPU instances. EC2 capacity is per instance type and per
# Availability Zone and cannot be checked in advance; with provision-strategy min every node uses ONE AZ (the first the region
# lists), so a shortage there blocks the whole fleet while the other AZs may have plenty. Karpenter logs the exact AWS reason.
diagnose_gpu_capacity() {
  local line msg azs
  command -v kubectl >/dev/null 2>&1 || return 0
  # Newest failure for the CURRENT instance type (older ones may be for a type used before), else the newest of any type.
  local logs itype
  itype="$(gpu_instance_type 2>/dev/null || true)"
  logs="$(kubectl -n karpenter logs deploy/karpenter --since=60m 2>/dev/null | grep 'failed launching nodeclaim' | grep 'straiker-gpu' || true)"
  line=""
  [[ -n "${itype}" ]] && line="$(printf '%s\n' "${logs}" | grep -F "sufficient ${itype} capacity" | tail -1 || true)"
  [[ -n "${line}" ]] || line="$(printf '%s\n' "${logs}" | tail -1)"
  [[ -n "${line}" ]] || return 0
  msg="$(printf '%s' "${line}" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.readline())
    print((d.get("error") or d.get("message") or "")[:420])
except Exception:
    pass' 2>/dev/null || true)"
  [[ -n "${msg}" ]] || return 0
  azs="$(aws ec2 describe-subnets --region "${AWS_REGION}" --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
    --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null | tr '\t' ' ' || true)"
  {
    echo ""
    echo "[*] The GPU nodes could not be created. AWS (via Karpenter) says:"
    echo "      ${msg}"
    if [[ "${msg}" == *InsufficientInstanceCapacity* || "${msg}" == *UnfulfillableCapacity* || "${msg}" == *"insufficient capacity"* ]]; then
      echo "[*] This is a temporary shortage of that instance type in the Availability Zone(s) this cluster launches nodes in (${azs:-unknown}),"
      echo "    not a quota or installer problem. Karpenter keeps retrying, so waiting and re-running this phase can succeed. To get unstuck sooner:"
      echo "      1. Allow another AZ: tag its private subnet  karpenter.sh/discovery=${CLUSTER_NAME}  (the strategy 'min' tags only the first AZ);"
      echo "         the message above usually names AZs that have capacity. For a new install use --provision-strategy ha (all AZs)."
      echo "      2. Use an instance type with capacity: re-run with --gpu-instance-type <type>, or --gpu-fleet per-model (smaller instances)."
      echo "      3. Reserve capacity (EC2 Capacity Reservation / Capacity Block) and pass --gpu-capacity-reservation cr-..."
    fi
    echo ""
  } >&2
}

# Plans where the model servers run (scripts/gpu_planner.py), prints it, blocks if the hardware cannot hold the fleet, and leaves
# the plan in INFERENCE_PLAN_FILE. production: one server per GPU on each model's validated tier (what Karpenter creates).
# test: the GPU nodes that exist now, shared if needed; with none, the same exclusive plan as production.
INFERENCE_PLAN_FILE=""
INFERENCE_NO_WAIT=false
plan_inference_gpus() {
  local models_csv=$1 profile nodes_json rc=0 sharing
  profile="$(inference_profile)"
  require_command python3
  nodes_json="$(kubectl get nodes -o json 2>/dev/null || true)"
  [[ -n "${nodes_json}" ]] || nodes_json='{"items":[]}'
  INFERENCE_PLAN_FILE="$(mktemp)"
  local node_type_args=()
  [[ "$(gpu_fleet)" == "p4d" ]] && node_type_args=(--node-type "$(gpu_instance_type)")
  printf '%s' "${nodes_json}" | python3 "${GPU_PLANNER}" --discover --profile "${profile}" --no-mig \
    --models "${GPU_MODELS_FILE}" --only "${models_csv}" ${node_type_args[@]+"${node_type_args[@]}"} >"${INFERENCE_PLAN_FILE}" || rc=$?
  if [[ ${rc} -ne 0 && ${rc} -ne 2 ]]; then
    mark_phase_blocked "The GPU planner failed (exit ${rc}); see its error above."
    return 1
  fi
  python3 "${GPU_PLANNER}" --summary "${INFERENCE_PLAN_FILE}" | while IFS= read -r line; do log "${line}"; done
  if [[ ${rc} -eq 2 ]]; then
    mark_phase_blocked "The GPUs cannot hold the model fleet: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("shortfall",""))' "${INFERENCE_PLAN_FILE}")"
    return 1
  fi
  sharing="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sharing"])' "${INFERENCE_PLAN_FILE}")"
  if [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "${INFERENCE_PLAN_FILE}")" == "projected" ]]; then
    # Servers that already have a running pod hold a node (and their vCPUs) already: only the rest need new nodes.
    local planned running=0 m
    planned="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["gpus_used"])' "${INFERENCE_PLAN_FILE}")"
    for m in ${models_csv//,/ }; do
      running=$((running + $(kubectl get pods -n "${INFRA_NAMESPACE}" --field-selector=status.phase=Running -o name 2>/dev/null \
        | grep -c "^pod/inference-${m}-" || true)))
    done
    [[ ${running} -gt ${planned} ]] && running=${planned}
    if [[ "$(gpu_fleet)" == "p4d" ]]; then
      # Whole packed nodes: the plan's node count minus the ones already in the cluster of that type.
      local want have azs itype
      itype="$(gpu_instance_type)"
      want="$(python3 "${GPU_PLANNER}" --nodes-needed "${INFERENCE_PLAN_FILE}" | awk -v t="${itype}" '$1 == t { print $2 }')"
      have="$(kubectl get nodes -l "node.kubernetes.io/instance-type=${itype}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
      azs="$(aws ec2 describe-subnets --region "${AWS_REGION}" --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
        --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null | tr '\t' '\n' | sort -u | tr '\n' ' ')"
      check_p4d_offered "${azs}" || return 1
      if [[ ${want:-0} -gt ${have:-0} ]]; then
        check_gpu_vcpu_quota $(( want - have )) || return 1
      else
        log "The ${have} ${itype} node(s) in the cluster hold the ${planned} model servers: no new GPU nodes needed."
      fi
    elif [[ ${planned} -gt ${running} ]]; then
      check_gpu_vcpu_quota $((planned - running)) || return 1
    else
      log "All ${planned} model servers already run: no new GPU nodes needed."
    fi
    apply_gpu_time_slicing 0 || return 1
  elif [[ "${sharing}" == "time-slicing" ]]; then
    apply_gpu_time_slicing "$(python3 "${GPU_PLANNER}" --slices "${INFERENCE_PLAN_FILE}")" || return 1
  else
    apply_gpu_time_slicing 0 || return 1
  fi
}

# Argus v3's context reviewer calls Bedrock (global.openai.gpt-5.6-sol / -terra) in every deployment, so a customer account without
# access would otherwise fail only at the first request. Uses the operator's credentials: it proves the models are enabled in this
# account and region, not that the pods' role is allowed (that role is created by the aws-data phase).
preflight_argus_v3_bedrock() {
  require_command aws
  local region profile out rc failed=() warned=()
  region="$(get_metadata "bedrock_region")"
  region="${region:-${AWS_REGION}}"
  for profile in ${ARGUS_V3_BEDROCK_PROFILES}; do
    rc=0
    out="$(aws bedrock-runtime converse --region "${region}" --model-id "${profile}" \
      --messages '[{"role":"user","content":[{"text":"hi"}]}]' --inference-config '{"maxTokens":16}' 2>&1)" || rc=$?
    if [[ ${rc} -eq 0 || "${out}" == *ThrottlingException* ]]; then
      log "Bedrock preflight OK: '${profile}' answers in ${region}."
    elif [[ "${out}" == *"not authorized to perform: bedrock:"* ]]; then
      warned+=("${profile}")
      log "WARNING: Bedrock preflight for '${profile}' is inconclusive: the installer's AWS identity may not call Bedrock (the pods use their own role)."
    elif [[ "${out}" == *ResourceNotFoundException* || "${out}" == *ValidationException* || "${out}" == *AccessDeniedException* || "${out}" == *"not supported"* ]]; then
      failed+=("${profile}")
      echo "  [!] ${profile} in ${region}: ${out}" >&2
    else
      warned+=("${profile}")
      log "WARNING: Bedrock preflight for '${profile}' is inconclusive: ${out}"
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    mark_phase_blocked "Bedrock is not usable for: ${failed[*]} in ${region}. Enable the models under Bedrock > Model access in that account and region (and check any SCP that denies bedrock:InvokeModel), then re-run."
    return 1
  fi
}

# Product -> inference model mapping (Defend's argus needs 4 backends, Ascend's
# iris needs 1). Derived from PRODUCTS_OPT fresh on every call rather than
# persisted separately, so it can never drift from the actual product
# selection captured earlier.
inference_models_for_products() {
  local models=()
  # --inference-mode bedrock: nothing runs on GPU here.
  if [[ "$(inference_mode)" == "bedrock" ]]; then
    return 0
  fi
  if [[ ",${PRODUCTS_OPT}," == *",defend,"* ]]; then
    # Argus v3's models (the manager's final list): vision/wanda (image checks) and the two Kev classifiers. antman, hulk,
    # quicksilver and thor are not deployed: the v3 controls that used them are off on-prem, on purpose.
    models+=("vision" "wanda" "kev-agentic" "kev-non-agentic")
  fi
  if [[ ",${PRODUCTS_OPT}," == *",ascend,"* ]]; then
    models+=("thanos")
  fi
  if [[ -n "${INFERENCE_MODELS}" ]]; then
    local kept=() m
    for m in "${models[@]+"${models[@]}"}"; do
      [[ ",${INFERENCE_MODELS}," == *",${m},"* ]] && kept+=("${m}")
    done
    models=("${kept[@]+"${kept[@]}"}")
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
    if [[ "$(inference_mode)" == "bedrock" ]]; then
      log "--inference-mode bedrock: no GPU inference models are deployed."
    else
      log "No selected product needs a GPU inference model — skipping."
    fi
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

  local gpu_wait_start=${SECONDS}
  local models_csv
  models_csv="$(IFS=','; echo "${models[*]}")"
  if [[ "$(gpu_fleet)" == "p4d" ]]; then
    check_gpu_reservations "$(p4d_nodes_for $((${#models[@]} * 2)))" || return
  fi
  plan_inference_gpus "${models_csv}" || return

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
  local capacity_verdict gpu_nodes_needed
  capacity_verdict="$(mktemp)"
  rm -f "${capacity_verdict}"
  if [[ "$(gpu_fleet)" == "p4d" ]]; then gpu_nodes_needed="$(p4d_nodes_for $((total * 2)))"; else gpu_nodes_needed=${total}; fi
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
      # Capacity can take hours: every release waits for its pods until the 6-hour limit (GPU_WAIT_HOURS) from the start of this phase.
      local gpu_wait_left=$(( ${GPU_WAIT_HOURS:-6} * 3600 - (SECONDS - gpu_wait_start) ))
      (( gpu_wait_left < 60 )) && gpu_wait_left=60
      log "Installing inference model '${model}' as release '${release}'..."
      local cmd=(
        helm upgrade --install "${release}" "$(chart_ref "${INFERENCE_CHART_NAME}")"
        --namespace "${INFRA_NAMESPACE}"
        --create-namespace
        --set "modelProfile=${model}"
        --set-string "modelCache.awsRegion=${AWS_REGION}" # the models bucket lives in the install region (chart falls back to us-east-1)
        --set "global.dockerRegistry=${ecr_registry_prefixed}"
        --set "global.modelBucket=$(model_bucket_uri "${models_bucket}")"
        --timeout "${gpu_wait_left}s"
      )
      if [[ "${INFERENCE_NO_WAIT}" != true ]]; then
        cmd+=(--wait)
      fi
      if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
        cmd+=(--set "cloudProvider=gke")
      elif [[ "$(gpu_fleet)" == "p4d" ]]; then
        cmd+=(--set "gpuProfile=$(gpu_chart_profile_for_instance_type "$(gpu_instance_type)")") # the packed fleet's GPU tier
      fi
      if [[ "$(gpu_fleet)" == "p4d" ]]; then
        local req_cpu req_mem
        read -r req_cpu req_mem <<< "$(gpu_pod_requests_for_types)"
        if [[ -n "${req_cpu:-}" ]]; then # a small size is in the list: requests must fit it, or Karpenter never picks that size
          cmd+=(--set-string "resources.requests.cpu=${req_cpu}" --set-string "resources.requests.memory=${req_mem}Gi")
        fi
      fi
      ha_enabled && cmd+=(--set-string "zoneSpread=strict") # one replica of each model per zone (needs GPU capacity in both)
      if [[ -n "${CHART_VERSION}" ]]; then
        cmd+=(--version "${CHART_VERSION}")
      fi
      # Shared GPUs (test profile only): the plan's serving settings (smaller context, quantization). Empty for production.
      local plan_set
      while IFS= read -r plan_set; do
        [[ -n "${plan_set}" ]] && cmd+=(--set "${plan_set}")
      done < <(python3 "${GPU_PLANNER}" --helm-sets "${INFERENCE_PLAN_FILE}" "${model}")

      local logfile
      logfile="$(mktemp)"
      ( "${cmd[@]}" ) >"${logfile}" 2>&1 &
      batch_models+=("${model}")
      batch_pids+=("$!")
      batch_logs+=("${logfile}")

      i=$((i + 1))
      j=$((j + 1))
    done

    # Fail fast: watch Karpenter while helm waits (see watch_gpu_capacity).
    local watcher_pid=""
    if [[ "${INFERENCE_NO_WAIT}" != true && "${CLOUD_PROVIDER}" != "gke" && "${STRAIKER_NO_GPU_WATCH:-}" != 1 ]]; then
      rm -f "${capacity_verdict}"
      watch_gpu_capacity "${capacity_verdict}" "${gpu_nodes_needed}" "${batch_pids[@]}" &
      watcher_pid=$!
    fi

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
    if [[ -n "${watcher_pid}" ]]; then
      kill "${watcher_pid}" 2>/dev/null || true
      wait "${watcher_pid}" 2>/dev/null || true
    fi
    [[ -s "${capacity_verdict}" ]] && break
  done

  rm -f "${INFERENCE_PLAN_FILE}"
  if [[ -s "${capacity_verdict}" ]]; then
    local v_reason v_elapsed v_nodes v_needed
    IFS='|' read -r v_reason v_elapsed v_nodes v_needed < "${capacity_verdict}"
    rm -f "${capacity_verdict}"
    diagnose_gpu_capacity
    local why
    case "${v_reason}" in
      hard) why="AWS refused to launch the GPU instances for a reason that waiting will not fix (see the AWS message above: quota, permission, image, subnet or reservation)." ;;
      pool) why="the GPU node pool's limit is reached, so Karpenter will not create more GPU nodes (raise --gpu-max-nodes)." ;;
      *) why="AWS has no capacity for the GPU instances right now (no GPU node came up)." ;;
    esac
    mark_phase_blocked "Stopped waiting for the model servers after $((v_elapsed / 60)) min instead of the full Helm timeout: ${why} Nothing is broken: the releases stay, Karpenter keeps retrying, and re-running this phase (--phase straiker-inference --rerun-phase) continues from here."
    return
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    diagnose_gpu_capacity
    mark_phase_blocked "Inference model(s) failed to install: ${failed[*]}. Each model is its own Helm release named 'inference-<model>' — check GPU node/capacity availability for the failed one(s), then re-run --phase straiker-inference --rerun-phase (already-succeeded models are just re-verified, not disrupted)."
    return
  fi
}

# Argus — always installed, regardless of product selection: charts/
# straiker-ascend's own iris calls Argus's /api/v1/detect directly for
# several detection categories, so an Ascend-only install still needs this
# running (not just customers who selected Defend as a product). Depends on
# straiker-system (Redis/OpenSearch/Benthos, shared NodePool) and straiker-
# inference's per-model releases (SYS__LLM_ENDPOINTS__* targets) already
# being up; checks straiker-system's live release status the same way
# phase_straiker_core does, since a phase that merely ran earlier isn't proof
# it's still healthy.
# Argus v3 (the Defend detection engine; charts/straiker-argus-v3, vendored from straiker-ai/argus feature/argus-v3). Needs the
# data layer: MSK (IAM), ElastiCache (TLS), the argus/v3 Secrets Manager bundle and the argus-sa Pod Identity role, all from aws-data.
# Runs next to v1 until Ascend is moved to v3 (its current image calls v1 directly); enabled with --defend-engine v3.
phase_straiker_argus_v3() {
  case "${DEFEND_ENGINE}" in
    v1 | v3) ;;
    *)
      mark_phase_blocked "--defend-engine must be v1 or v3 (got '${DEFEND_ENGINE}')."
      return
      ;;
  esac
  if [[ "${DEFEND_ENGINE}" != "v3" ]]; then
    log "Argus v3 is not selected (--defend-engine v1): skipping."
    return
  fi
  require_command helm
  require_command kubectl
  require_command aws

  if [[ "${DATA_LAYER}" != "true" ]]; then
    mark_phase_blocked "Argus v3 needs --data-layer: it runs on MSK, ElastiCache and Secrets Manager (phase aws-data)."
    return
  fi
  preflight_argus_v3_bedrock || return

  local infra_status
  infra_status="$(helm status "${INFRA_RELEASE}" -n "${INFRA_NAMESPACE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
  if [[ "${infra_status}" != "deployed" ]]; then
    mark_phase_blocked "Release '${INFRA_RELEASE}' in namespace '${INFRA_NAMESPACE}' is not healthy (status: '${infra_status:-not installed}'). Argus v3 needs it first."
    return
  fi

  local ecr_registry redis_endpoint msk_arn grid_bucket
  ecr_registry="$(get_metadata "ecr_registry")"
  redis_endpoint="$(get_metadata "data_redis_endpoint")"
  msk_arn="$(get_metadata "msk_cluster_arn")"
  grid_bucket="$(get_metadata "grid_artifacts_bucket")"
  if [[ -z "${ecr_registry}" || -z "${redis_endpoint}" || -z "${msk_arn}" || -z "${grid_bucket}" ]]; then
    mark_phase_blocked "Missing ecr_registry / data_redis_endpoint / msk_cluster_arn / grid_artifacts_bucket in install state. Run phases 'aws-artifacts' and 'aws-data' first."
    return
  fi

  local brokers
  brokers="$(aws kafka get-bootstrap-brokers --cluster-arn "${msk_arn}" --region "${AWS_REGION}" \
    --query 'BootstrapBrokerStringSaslIam' --output text 2>/dev/null || true)"
  if [[ -z "${brokers}" || "${brokers}" == "None" ]]; then
    mark_phase_blocked "Could not get SASL/IAM bootstrap brokers for ${msk_arn}."
    return
  fi

  ensure_k8s_ready_for_charts || return
  ensure_argus_v3_secret || return

  local chart="${REPO_ROOT}/charts/straiker-argus-v3"
  if [[ ! -f "${chart}/values-onprem.yaml" ]]; then
    mark_phase_blocked "charts/straiker-argus-v3/values-onprem.yaml not found: this phase needs the in-workspace chart."
    return
  fi
  local ns="${INFRA_NAMESPACE}" svc_suffix="svc.cluster.local"
  local bedrock_region
  bedrock_region="$(get_metadata "bedrock_region")"
  bedrock_region="${bedrock_region:-${AWS_REGION}}"

  local cmd=(
    helm upgrade --install "${ARGUS_V3_RELEASE}" "${chart}"
    --namespace "${ns}"
    -f "${chart}/values-onprem.yaml"
    --set-string "image.repository=$(docker_registry_with_prefix "${ecr_registry}")/straiker/argus"
    --set-string "argus.secretManager.region=${AWS_REGION}"
    --set-string "argus.secretManager.secretName=${CLUSTER_NAME}/${ARGUS_V3_SECRET}"
    --set-string "argus.redis.url=rediss://${redis_endpoint}:6379"
    --set-string "argus.compactor.bucket=${grid_bucket}"
    --set-string "argus.compactor.region=${AWS_REGION}"
    --set-string "argus.copilot.platformRegistryUrl=http://registry.${ns}.${svc_suffix}:80"
    --set-string "argus.contextReview.region=${bedrock_region}"
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  # MSK (IAM): every producer/consumer block gets the same brokers and region.
  local block
  for block in agentConfig grid transcript metricsStream compactor; do
    cmd+=(--set-string "argus.${block}.bootstrapServers=${brokers}" --set-string "argus.${block}.region=${AWS_REGION}")
  done
  # Model endpoints: only for the servers this install deploys. An unset endpoint leaves its controls "unavailable".
  local models_deployed
  models_deployed=" $(inference_models_for_products | tr '\n' ' ') "
  if [[ "${models_deployed}" == *" vision "* ]]; then
    cmd+=(--set-string "argus.llmEndpoints.vision=http://inference-vision.${ns}.${svc_suffix}:8000/v1/chat/completions")
  fi
  if [[ "${models_deployed}" == *" wanda "* ]]; then
    cmd+=(--set-string "argus.llmEndpoints.imageDetection=http://inference-wanda.${ns}.${svc_suffix}:8000/v1/chat/completions")
  fi
  if [[ "${models_deployed}" == *" kev-agentic "* ]]; then
    cmd+=(--set-string "argus.llmEndpoints.kev=http://inference-kev-agentic.${ns}.${svc_suffix}:8000/v1/detect")
  fi
  # Prompt Kev needs a kev-server of its own (SaaS runs kev-lw-4b-prompt): sharing the agentic one queues ~100-token prompts
  # behind trace chunks (seconds instead of ~0.1 s). None is deployed, so it is off.
  cmd+=(--set "argus.llmEndpoints.kevPrompt=false")

  "${cmd[@]}"
}

phase_straiker_defend() {
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
    helm upgrade --install "${DEFEND_RELEASE}" "$(chart_ref "${DEFEND_CHART_NAME}")"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --set "global.dockerRegistry=${ecr_registry_prefixed}"
    --set "global.modelBucket=$(model_bucket_uri "${models_bucket}")"
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  ha_enabled && cmd+=(--set "replicas=2")
  # --data-layer: Redis is ElastiCache Serverless (TLS only), not straiker-system's valkey.
  if [[ "${DATA_LAYER}" == "true" ]]; then
    local redis_endpoint
    redis_endpoint="$(get_metadata "data_redis_endpoint")"
    if [[ -z "${redis_endpoint}" ]]; then
      mark_phase_blocked "No data_redis_endpoint in install state. Run phase 'aws-data' first."
      return
    fi
    cmd+=(--set-string "redis.url=rediss://${redis_endpoint}:6379")
    ensure_synced_secret defend-session-source "${CLUSTER_NAME}/argus/session" straiker-defend-session-secret "%s" \
      "SYS__ARGUS_SESSION_SECRET_KEY" || return
    cmd+=(--set-string "sessionKeySecret=defend-session-source")
  fi
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

  "${cmd[@]}" || return
  apply_ha_pdbs "${INFRA_NAMESPACE}" straiker-ascend-control-plane
}

# --force-conflicts resolves a field-manager conflict from an out-of-band edit
# (e.g. `kubectl set env`) instead of failing the upgrade outright. It is only
# meaningful under server-side apply, and Helm rejects it outright otherwise:
#   invalid client update option(s): forceConflicts enabled when serverSideApply disabled
#
# Helm 4 does NOT simply default to server-side apply, despite what an earlier
# version of this comment claimed. Per `helm upgrade --help`, --server-side
# defaults to "auto", and auto "defaults the value from the previous chart
# release's method" -- so a release first installed by an older client-side
# Helm keeps resolving to client-side on every later upgrade, no matter how new
# the client is. That is exactly the Omada case: the release was created by AWS
# CloudShell's preinstalled Helm, so a Helm 4 client passing --force-conflicts
# alone still failed.
#
# Hence both flags travel together: --server-side=true is what makes
# --force-conflicts meaningful, and --force-conflicts is what makes the
# resulting client-side -> server-side field-ownership handover succeed rather
# than erroring on every field Helm's old client-side manager owned.
#
# Still feature-detected, not assumed: Helm 3 has neither flag, and passing an
# unrecognized one is a hard "unknown flag" error, not a harmless no-op.
helm_ssa_conflict_flags() {
  local help
  help="$(helm upgrade --help 2>/dev/null || true)"
  [[ "${help}" == *"--force-conflicts"* && "${help}" == *"--server-side"* ]]
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

  # charts/straiker-ascend runs db-migrate as a pre-install/pre-upgrade hook.
  # Hooks run before plain resources, so the chart's own ServiceAccount may not
  # exist yet when the hook Job starts. Pre-create it here with the correct Helm
  # ownership labels so Helm can adopt it without an "invalid ownership metadata"
  # error on subsequent installs/upgrades.
  kubectl create serviceaccount "${ASCEND_SERVICE_ACCOUNT}" \
    -n "${INFRA_NAMESPACE}" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  kubectl annotate serviceaccount "${ASCEND_SERVICE_ACCOUNT}" -n "${INFRA_NAMESPACE}" \
    "meta.helm.sh/release-name=${ASCEND_RELEASE}" \
    "meta.helm.sh/release-namespace=${INFRA_NAMESPACE}" \
    --overwrite >/dev/null
  kubectl label serviceaccount "${ASCEND_SERVICE_ACCOUNT}" -n "${INFRA_NAMESPACE}" \
    "app.kubernetes.io/managed-by=Helm" \
    --overwrite >/dev/null

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  # --data-layer: iris's DB is Aurora and its Redis is ElastiCache (TLS). Password from
  # straiker-data's DSN Secret; Aurora requires TLS (the DSNs use sslmode=require).
  local ascend_db_host="postgres.${INFRA_NAMESPACE}.svc.cluster.local"
  local ascend_data_layer_args=()
  if [[ "${DATA_LAYER}" == "true" ]]; then
    # iris lives in the "ascend" Aurora cluster; an install with a single cluster keeps it on "platform".
    ascend_db_host="$(get_metadata "aurora_ascend_endpoint")"
    [[ -n "${ascend_db_host}" ]] || ascend_db_host="$(get_metadata "aurora_endpoint")"
    local ascend_redis_endpoint
    ascend_redis_endpoint="$(get_metadata "data_redis_endpoint")"
    if [[ -z "${ascend_db_host}" || -z "${ascend_redis_endpoint}" ]]; then
      mark_phase_blocked "Missing aurora_endpoint/data_redis_endpoint in install state. Run phase 'aws-data' first."
      return
    fi
    ascend_data_layer_args=(
      --set "db.port=$(get_metadata "aurora_port")"
      --set "db.sslMode=require"
      --set "db.passwordSecret.name=straiker-db-dsn"
      --set "db.passwordSecret.key=PASSWORD_iris"
    )
    # iris's own node-based Valkey (SaaS shape, TLS + AUTH): connection details live in Secrets Manager;
    # copy them into a K8s Secret so the token never appears in Helm values or the pod spec.
    # Without it (older stack), fall back to the shared serverless cache.
    local iris_redis_secret
    iris_redis_secret="$(get_metadata "iris_redis_secret_name")"
    if [[ -n "${iris_redis_secret}" ]]; then
      ensure_iris_redis_secret "${iris_redis_secret}" || return
      ascend_data_layer_args+=(--set "redis.existingSecret.name=iris-redis")
    else
      ascend_data_layer_args+=(--set-string "redis.url=rediss://${ascend_redis_endpoint}:6379")
    fi
  fi

  # Argus v3 for the graders: the in-cluster api-gateway (plain HTTP behind the NLB, Service port 443). Iris still uses v1 until the
  # iris-grader key (ARGUS_V3_API_KEY in straiker-secrets) exists, so this is safe to set before the key is minted.
  local ascend_v3_args=()
  if [[ "${DEFEND_ENGINE}" == "v3" ]]; then
    ascend_v3_args=(--set-string "argus.v3.endpoint=http://api-gateway.${INFRA_NAMESPACE}.svc.cluster.local:443/api/v3/detect")
    if [[ -n "${ARGUS_V3_GRADER_KEY:-}" ]]; then
      patch_shared_secret "ARGUS_V3_API_KEY" "${ARGUS_V3_GRADER_KEY}"
      log "Stored the iris-grader key as ARGUS_V3_API_KEY: Ascend will grade through Argus v3."
    elif ! kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.ARGUS_V3_API_KEY}' 2>/dev/null | grep -q .; then
      log "NOTE: no iris-grader key yet (ARGUS_V3_API_KEY): Ascend keeps grading through Argus v1. Mint one (runbook 'Ascend on Argus v3') and re-run this phase with ARGUS_V3_GRADER_KEY set."
    fi
  fi

  local cmd=(
    helm upgrade --install "${ASCEND_RELEASE}" "$(chart_ref "${ASCEND_CHART_NAME}")"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --set "global.dockerRegistry=$(docker_registry_with_prefix "${ecr_registry}")"
    --set-string "db.host=${ascend_db_host}"
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  ha_enabled && cmd+=(--set "controlPlane.replicaCount=2")
  cmd+=("${ascend_data_layer_args[@]+"${ascend_data_layer_args[@]}"}")
  cmd+=("${ascend_v3_args[@]+"${ascend_v3_args[@]}"}")
  # See helm_ssa_conflict_flags's declaration above for why these can't just
  # always be passed, and why they must be passed together. (Note: `kubectl
  # patch --type=json remove metadata/managedFields` does NOT work as an
  # alternative fix on Helm 4 -- the API server recomputes managedFields from
  # the request and ignores a direct edit to that field.)
  helm_ssa_conflict_flags && cmd+=(--server-side=true --force-conflicts)
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

  # bedrock: iris's resolver (iris/generators/llm/resolver.py) refuses to
  # pick a (provider, model) not explicitly allow-listed in
  # SYS__AVAILABLE_MODELS, even though bifrost itself would happily route
  # to it — without this, every AI-driven feature (not just the recon
  # agent) fails outright in bedrock mode. Pinned to the exact two model
  # IDs the codebase ever asks for today, by their bare logical name (see
  # resolver.BEDROCK_MODEL_IDS) — NOT the ARN-versioned AWS id or any
  # inference-profile prefix, both of which resolver.py stitches on itself
  # from SYS__BEDROCK_INFERENCE_PROFILE (set below) at call time. The
  # installer grants pod IAM access; AWS still needs the selected Bedrock
  # models enabled for the account.
  if [[ "${AI_PROVIDER_MODE}" == "bedrock" ]]; then
    cmd+=(--set "availableModels[0]=bedrock/claude-haiku-4-5")
    cmd+=(--set "availableModels[1]=bedrock/claude-sonnet-4-6")
    local bedrock_inference_profile
    bedrock_inference_profile="$(get_metadata "bedrock_inference_profile")"
    if [[ -n "${bedrock_inference_profile}" ]]; then
      cmd+=(--set "bedrockInferenceProfile=${bedrock_inference_profile}")
    fi
  fi

  # EDGE_TYPE=none/alb/xalb/tailscale + a captured CUSTOM_ORIGIN_DOMAIN:
  # dataExfiltrationEndpoint/corsAllowOrigins otherwise default to the same
  # Caddy-style formula as straiker-frontend.frontend.origin above (see this
  # chart's own "ascend.externalUrl"/"ascend.frontendOrigin" helpers) —
  # override with the real hostname for the same reason. See
  # CUSTOM_ORIGIN_DOMAIN's declaration.
  if [[ "${EDGE_TYPE}" == "none" || "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" || "${EDGE_TYPE}" == "tailscale" ]]; then
    local custom_domain
    custom_domain="$(get_metadata "custom_domain")"
    if [[ -n "${custom_domain}" ]]; then
      cmd+=(--set "dataExfiltrationEndpoint=https://$(custom_domain_hostname straiker-ascend)")
      cmd+=(--set "corsAllowOrigins=https://$(custom_domain_hostname straiker)")
    elif [[ "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" || "${EDGE_TYPE}" == "tailscale" ]]; then
      mark_phase_blocked "Missing custom_domain from install state. Re-run with --edge-type ${EDGE_TYPE} so it's captured."
      return
    fi
  fi

  "${cmd[@]}" || return
  apply_ha_pdbs "${INFRA_NAMESPACE}" straiker-edge
}

# Tailscale Kubernetes operator (third-party chart, not Straiker's) — only
# runs when EDGE_TYPE=tailscale. Watches straiker-edge's Service for the
# tailscale.com/expose: "true" annotation and exposes it onto the tailnet at
# L3 (no IngressClass involved — see charts/straiker-edge's templates/
# service.yaml). Runs after shared-secrets (needs SHARED_SECRETS_NAME to
# already exist) and before straiker-edge (which depends on this release
# being healthy).
phase_tailscale_operator() {
  if [[ "${EDGE_TYPE}" != "tailscale" ]]; then
    log "Edge type is '${EDGE_TYPE:-none}', not 'tailscale' — skipping the Tailscale operator."
    return
  fi

  require_command helm
  require_command kubectl

  if ! kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
    mark_phase_blocked "Secret '${SHARED_SECRETS_NAME}' doesn't exist yet. Run phase 'shared-secrets' first."
    return
  fi

  ensure_k8s_ready_for_charts || return

  if [[ -n "${TAILSCALE_OAUTH_CLIENT_ID}" && -n "${TAILSCALE_OAUTH_CLIENT_SECRET}" ]]; then
    patch_shared_secret "TAILSCALE_OAUTH_CLIENT_ID" "${TAILSCALE_OAUTH_CLIENT_ID}"
    patch_shared_secret "TAILSCALE_OAUTH_CLIENT_SECRET" "${TAILSCALE_OAUTH_CLIENT_SECRET}"
    log "Stored the Tailscale OAuth client in '${SHARED_SECRETS_NAME}'."
  else
    log "No new Tailscale OAuth client to store (already present in '${SHARED_SECRETS_NAME}', or none captured)."
  fi

  local client_id client_secret
  client_id="$(kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.TAILSCALE_OAUTH_CLIENT_ID}' 2>/dev/null | base64 -d || true)"
  client_secret="$(kubectl get secret "${SHARED_SECRETS_NAME}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.data.TAILSCALE_OAUTH_CLIENT_SECRET}' 2>/dev/null | base64 -d || true)"
  if [[ -z "${client_id}" || -z "${client_secret}" ]]; then
    mark_phase_blocked "No Tailscale OAuth client in '${SHARED_SECRETS_NAME}'. Re-run with --edge-type tailscale and TAILSCALE_OAUTH_CLIENT_ID/TAILSCALE_OAUTH_CLIENT_SECRET set (or answer the prompts), or seed the secret directly: kubectl patch secret ${SHARED_SECRETS_NAME} -n ${INFRA_NAMESPACE} --type=merge -p '{\"stringData\":{\"TAILSCALE_OAUTH_CLIENT_ID\":\"...\",\"TAILSCALE_OAUTH_CLIENT_SECRET\":\"...\"}}'."
    return
  fi

  helm repo add --force-update "${TAILSCALE_HELM_REPO_NAME}" "${TAILSCALE_HELM_REPO_URL}" >/dev/null
  helm repo update "${TAILSCALE_HELM_REPO_NAME}" >/dev/null

  local cmd=(
    helm upgrade --install "${TAILSCALE_OPERATOR_RELEASE}" "${TAILSCALE_HELM_REPO_NAME}/tailscale-operator"
    --namespace "${TAILSCALE_OPERATOR_NAMESPACE}"
    --create-namespace
    --wait
    --timeout "${HELM_TIMEOUT}"
    --set-string "oauth.clientId=${client_id}"
    --set-string "oauth.clientSecret=${client_secret}"
  )
  # The chart's own defaults (operatorConfig.defaultTags=tag:k8s-operator,
  # proxyConfig.defaultTags=tag:k8s) already match what
  # examples/edge/tailscale.md walks customers through setting up
  # themselves — no override needed, always bring-your-own now.
  "${cmd[@]}"
}

# Installs the AWS Load Balancer Controller itself via its Helm chart —
# relevant for EDGE_TYPE=alb or xalb (both render an ALB Ingress).
# terraform/aws/edge's alb_controller.tf (run by phase_edge_infra, which
# must run first) creates the IAM role/Pod Identity association this needs;
# this phase just points the chart at the matching ServiceAccount name (Pod
# Identity binds by namespace+name, no annotation needed, unlike IRSA).
# Skips entirely if an 'alb' IngressClass already exists — could be
# ours from a prior run (safe/idempotent to leave alone) or a customer's own
# pre-existing controller for other workloads on this cluster (installing a
# second, differently-configured controller managing the same IngressClass
# would race/conflict with it rather than coexist).
phase_alb_controller() {
  if [[ "${EDGE_TYPE}" != "alb" && "${EDGE_TYPE}" != "xalb" ]]; then
    log "Edge type is '${EDGE_TYPE:-none}', not 'alb'/'xalb' — skipping the AWS Load Balancer Controller."
    set_phase_status "${CURRENT_PHASE}" "skipped" "EDGE_TYPE not alb/xalb."
    return
  fi

  require_command helm
  require_command kubectl
  ensure_k8s_ready_for_charts || return

  if kubectl get ingressclass alb >/dev/null 2>&1; then
    log "IngressClass 'alb' already exists — assuming a controller is already managing it (ours from a prior run, or a pre-existing one). Skipping install to avoid a conflicting second controller. If this is stale/broken, delete it and re-run this phase."
    set_phase_status "${CURRENT_PHASE}" "skipped" "IngressClass 'alb' already exists."
    return
  fi

  local role_arn
  role_arn="$(get_metadata "alb_controller_role_arn")"
  if [[ -z "${role_arn}" ]]; then
    mark_phase_blocked "Missing alb_controller_role_arn from install state. Re-run phase 'edge-infra' first (--phase edge-infra --rerun-phase)."
    return
  fi

  local cluster_name
  cluster_name="$(get_metadata "cluster_name")"

  helm repo add --force-update "${ALB_CONTROLLER_HELM_REPO_NAME}" "${ALB_CONTROLLER_HELM_REPO_URL}" >/dev/null
  helm repo update "${ALB_CONTROLLER_HELM_REPO_NAME}" >/dev/null

  helm upgrade --install "${ALB_CONTROLLER_RELEASE}" "${ALB_CONTROLLER_HELM_REPO_NAME}/aws-load-balancer-controller" \
    --version "${ALB_CONTROLLER_VERSION}" \
    --namespace "${ALB_CONTROLLER_NAMESPACE}" \
    --create-namespace \
    --set "clusterName=${cluster_name}" \
    --set "serviceAccount.create=true" \
    --set "serviceAccount.name=${ALB_CONTROLLER_SERVICE_ACCOUNT}" \
    --wait \
    --timeout "${HELM_TIMEOUT}"
}

# Installs ExternalDNS via its Helm chart — only relevant for EDGE_TYPE=xalb
# with Route53 automation opted into (XALB_ROUTE53_AUTOMATION, resolved by
# capture_install_config's xalb block). terraform/aws/edge's
# external_dns.tf (run by phase_edge_infra, which must run first) creates
# the IAM role/Pod Identity association this needs. Skips (idempotent) if
# an 'external-dns' Deployment already exists — same reasoning as
# phase_alb_controller's IngressClass check: could be ours from a prior
# run, or a pre-existing one managing other DNS on this cluster that a
# second, differently-configured instance would conflict with.
phase_external_dns() {
  if [[ "${EDGE_TYPE}" != "xalb" || "$(get_metadata "xalb_route53_automation")" != "true" ]]; then
    log "Skipping ExternalDNS — only needed for edge type 'xalb' with Route53 automation enabled."
    set_phase_status "${CURRENT_PHASE}" "skipped" "Not applicable for this edge type/Route53 choice."
    return
  fi

  require_command helm
  require_command kubectl
  ensure_k8s_ready_for_charts || return

  if kubectl get deployment -n "${EXTERNAL_DNS_NAMESPACE}" external-dns >/dev/null 2>&1; then
    log "Deployment 'external-dns' already exists in namespace '${EXTERNAL_DNS_NAMESPACE}' — assuming it's already managing DNS (ours from a prior run, or a pre-existing one). Skipping install to avoid a conflicting second instance."
    set_phase_status "${CURRENT_PHASE}" "skipped" "external-dns Deployment already exists."
    return
  fi

  local role_arn
  role_arn="$(get_metadata "external_dns_role_arn")"
  if [[ -z "${role_arn}" ]]; then
    mark_phase_blocked "Missing external_dns_role_arn from install state. Re-run phase 'edge-infra' first (--phase edge-infra --rerun-phase)."
    return
  fi

  local domain
  domain="$(get_metadata "custom_domain")"
  local cluster_name
  cluster_name="$(get_metadata "cluster_name")"

  helm repo add --force-update "${EXTERNAL_DNS_HELM_REPO_NAME}" "${EXTERNAL_DNS_HELM_REPO_URL}" >/dev/null
  helm repo update "${EXTERNAL_DNS_HELM_REPO_NAME}" >/dev/null

  helm upgrade --install "${EXTERNAL_DNS_RELEASE}" "${EXTERNAL_DNS_HELM_REPO_NAME}/external-dns" \
    --version "${EXTERNAL_DNS_VERSION}" \
    --namespace "${EXTERNAL_DNS_NAMESPACE}" \
    --create-namespace \
    --set "provider.name=aws" \
    --set "policy=upsert-only" \
    --set "txtOwnerId=${cluster_name}" \
    --set "domainFilters[0]=${domain}" \
    --set "serviceAccount.create=true" \
    --set "serviceAccount.name=${EXTERNAL_DNS_SERVICE_ACCOUNT}" \
    --wait \
    --timeout "${HELM_TIMEOUT}"
}

# terraform/aws/edge — runs for every EDGE_TYPE=alb/xalb install. Always
# creates the AWS Load Balancer Controller's IAM role (phase_alb_controller
# needs this regardless of anything else). No self-signed certificate for
# either edge type — both require an explicit --alb-certificate-arn by
# default (see capture_install_config's alb/xalb blocks); xalb's opt-in
# --xalb-route53 instead auto-issues+validates a real ACM certificate via
# Route53 DNS validation and skips the ARN requirement, for the common case
# where the domain's zone is in this same AWS account. alb also gets an
# optional tiny SSM-accessible verification bastion when requested. Runs before
# phase_alb_controller/phase_external_dns/phase_straiker_edge so
# alb_controller_role_arn/alb_certificate_arn/external_dns_role_arn are
# populated by the time those need them. Uses Terraform (not raw `aws` CLI
# calls) so uninstall-straiker.sh's `tofu destroy` can clean all of this up
# too.
phase_edge_infra() {
  require_command aws
  require_command tofu

  if [[ "${EDGE_TYPE}" != "alb" && "${EDGE_TYPE}" != "xalb" && "${EDGE_TYPE}" != "tailscale" ]]; then
    log "Edge type is '${EDGE_TYPE:-none}', not 'alb'/'xalb'/'tailscale' — skipping edge infra."
    set_phase_status "${CURRENT_PHASE}" "skipped" "EDGE_TYPE not alb/xalb/tailscale."
    return
  fi

  require_terraform_dir "${EDGE_INFRA_SRC}" || return
  sync_terraform_workdir "${EDGE_INFRA_SRC}" "${EDGE_INFRA_DIR}"

  local bucket_name
  bucket_name="$(get_metadata "bootstrap_bucket")"
  if [[ -z "${bucket_name}" ]]; then
    bucket_name="$(resolve_bucket_name)"
  fi
  if ! aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
    mark_phase_blocked "Bootstrap bucket '${bucket_name}' not found. Run phase 'eks-tfbe' first."
    return
  fi
  write_edge_infra_backend_config "${bucket_name}"

  # alb/xalb need the ALB controller's IAM role; tailscale needs
  # cert-manager's instead (no ALB controller in that mode at all).
  # alb/xalb each independently opt into a certificate + Route53 zone
  # access via their own --alb-route53/--xalb-route53 flag (alb's never
  # also installs ExternalDNS — see ALB_ROUTE53_AUTOMATION's declaration).
  local enable_alb_controller enable_route53 enable_external_dns enable_cert_manager domain
  case "${EDGE_TYPE}" in
    tailscale)
      enable_alb_controller=false
      enable_route53=false
      enable_external_dns=false
      enable_cert_manager=true
      domain="$(get_metadata "custom_domain")"
      ;;
    alb)
      enable_alb_controller=true
      enable_route53="$([[ "$(get_metadata "alb_route53_automation")" == "true" ]] && echo true || echo false)"
      enable_external_dns=false
      enable_cert_manager=false
      domain="$(get_metadata "custom_domain")"
      ;;
    xalb)
      enable_alb_controller=true
      enable_route53="$([[ "$(get_metadata "xalb_route53_automation")" == "true" ]] && echo true || echo false)"
      enable_external_dns="$([[ "$(get_metadata "xalb_route53_automation")" == "true" ]] && echo true || echo false)"
      enable_cert_manager=false
      domain="$(get_metadata "custom_domain")"
      ;;
    *)
      enable_alb_controller=true
      enable_route53=false
      enable_external_dns=false
      enable_cert_manager=false
      domain=""
      ;;
  esac
  local san_hostnames_json
  san_hostnames_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
    "$(custom_domain_hostname straiker)" "$(custom_domain_hostname straiker-defend)" "$(custom_domain_hostname straiker-ascend)")"

  # AWS WAF for the ALB edge types (waf.tf). Per-host source allowlists: the console hosts get
  # --internal-lb-source-ranges, the api-gateway (when it rides the xalb ALB) gets --gateway-allowed-cidrs. One shared
  # ALB has one security group, so per-host ranges can only be enforced here.
  local enable_waf=false waf_args=() waf_hosts_json='{}'
  if [[ "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" ]]; then
    enable_waf=true
    [[ -n "${WAF_RATE_LIMIT}" ]] && set_metadata "waf_rate_limit" "${WAF_RATE_LIMIT}"
    if [[ -n "$(get_metadata "waf_rate_limit")" ]]; then
      waf_args+=(-var="waf_rate_limit=$(get_metadata "waf_rate_limit")")
    fi
    if [[ "${EDGE_TYPE}" == "xalb" ]]; then
      local api_host="" api_cidrs=""
      if gateway_via_alb; then
        api_host="$(get_metadata "gateway_domain")"
        api_cidrs="$(get_metadata "gateway_allowed_cidrs")"
      fi
      waf_hosts_json="$(CONSOLE_CIDRS="$(get_metadata "internal_lb_source_ranges")" API_HOST="${api_host}" API_CIDRS="${api_cidrs}" \
        python3 -c '
import json, os, sys
split = lambda v: [c.strip() for c in v.split(",") if c.strip()]
out = {}
console = split(os.environ["CONSOLE_CIDRS"])
if console:
    for h in sys.argv[1:]:
        out[h] = console
api = split(os.environ["API_CIDRS"])
if os.environ["API_HOST"] and api:
    out[os.environ["API_HOST"]] = api
print(json.dumps(out))
' "$(custom_domain_hostname straiker)" "$(custom_domain_hostname straiker-defend)" "$(custom_domain_hostname straiker-ascend)")"
    fi
  fi

  tofu_init "${EDGE_INFRA_DIR}" -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${EDGE_INFRA_DIR}" apply -auto-approve -input=false \
    -var="region=${AWS_REGION}" \
    -var="prefix=${TF_PREFIX}" \
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="san_hostnames=${san_hostnames_json}" \
    -var="enable_bastion=$([[ "$(get_metadata "alb_provision_bastion")" == "true" ]] && echo true || echo false)" \
    -var="enable_alb_controller=${enable_alb_controller}" \
    -var="alb_controller_namespace=${ALB_CONTROLLER_NAMESPACE}" \
    -var="alb_controller_service_account_name=${ALB_CONTROLLER_SERVICE_ACCOUNT}" \
    -var="enable_route53_automation=${enable_route53}" \
    -var="domain=${domain}" \
    -var="enable_external_dns=${enable_external_dns}" \
    -var="external_dns_namespace=${EXTERNAL_DNS_NAMESPACE}" \
    -var="external_dns_service_account_name=${EXTERNAL_DNS_SERVICE_ACCOUNT}" \
    -var="enable_cert_manager_route53=${enable_cert_manager}" \
    -var="cert_manager_namespace=${CERT_MANAGER_NAMESPACE}" \
    -var="cert_manager_service_account_name=${CERT_MANAGER_SERVICE_ACCOUNT}" \
    -var="enable_waf=${enable_waf}" \
    -var="waf_host_allowlists=${waf_hosts_json}" \
    ${waf_args[@]+"${waf_args[@]}"}

  set_metadata "waf_web_acl_arn" "$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw waf_web_acl_arn 2>/dev/null || true)"
  set_metadata "waf_log_group" "$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw waf_log_group_name 2>/dev/null || true)"
  [[ -n "$(get_metadata "waf_web_acl_arn")" ]] && log "AWS WAF Web ACL: $(get_metadata "waf_web_acl_arn") (logs: CloudWatch $(get_metadata "waf_log_group"))."

  local controller_role_arn dns_cert_arn bastion_id external_dns_role_arn cert_manager_role_arn route53_zone_id
  controller_role_arn="$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw alb_controller_role_arn)"
  dns_cert_arn="$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw dns_validated_certificate_arn)"
  bastion_id="$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw bastion_instance_id)"
  external_dns_role_arn="$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw external_dns_role_arn)"
  cert_manager_role_arn="$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw cert_manager_role_arn)"
  route53_zone_id="$(tofu -chdir="${EDGE_INFRA_DIR}" output -raw route53_hosted_zone_id)"
  if [[ -n "${controller_role_arn}" ]]; then
    set_metadata "alb_controller_role_arn" "${controller_role_arn}"
  fi
  if [[ -n "${dns_cert_arn}" ]]; then
    set_metadata "alb_certificate_arn" "${dns_cert_arn}"
  fi
  if [[ -n "${bastion_id}" ]]; then
    set_metadata "alb_bastion_instance_id" "${bastion_id}"
  fi
  if [[ -n "${external_dns_role_arn}" ]]; then
    set_metadata "external_dns_role_arn" "${external_dns_role_arn}"
  fi
  if [[ -n "${cert_manager_role_arn}" ]]; then
    set_metadata "cert_manager_role_arn" "${cert_manager_role_arn}"
  fi
  if [[ -n "${route53_zone_id}" ]]; then
    set_metadata "tailscale_hosted_zone_id" "${route53_zone_id}"
  fi

  if [[ -n "${dns_cert_arn}" ]]; then
    log "Issued a real, DNS-validated certificate: ${dns_cert_arn} — no browser warning."
  fi
  if [[ -n "${bastion_id}" ]]; then
    log ""
    log "Bastion '${bastion_id}' provisioned for pre-handoff verification. Connect with:"
    log "  aws ssm start-session --target ${bastion_id} --document-name AWS-StartPortForwardingSessionToRemoteHost \\"
    log "    --parameters '{\"host\":[\"<alb-dns-name>\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}'"
    log "then browse to https://localhost:8443 (real certificate — no browser warning to expect)."
  fi
}

# cert-manager (third-party chart, not Straiker's) — only runs when
# EDGE_TYPE=tailscale. Only installs the controller/CRDs; the
# ClusterIssuer/Certificate that actually request a certificate come from
# charts/straiker-edge itself (templates/cert-manager.yaml), applied by
# phase_straiker_edge below. Needs the IAM role phase_edge_infra creates
# (cert_manager.tf) through Pod Identity — runs after it, before
# straiker-edge (whose Certificate needs cert-manager's CRDs to already be
# registered). Skips if already healthy.
phase_cert_manager() {
  if [[ "${EDGE_TYPE}" != "tailscale" ]]; then
    log "Edge type is '${EDGE_TYPE:-none}', not 'tailscale' — skipping cert-manager."
    set_phase_status "${CURRENT_PHASE}" "skipped" "EDGE_TYPE not tailscale."
    return
  fi

  require_command helm
  require_command kubectl

  local status
  status="$(helm status "${CERT_MANAGER_RELEASE}" -n "${CERT_MANAGER_NAMESPACE}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
  if [[ "${status}" == "deployed" ]]; then
    log "cert-manager already installed and healthy — skipping."
    return
  fi

  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${CERT_MANAGER_HELM_REPO_NAME}" "${CERT_MANAGER_HELM_REPO_URL}" >/dev/null
  helm repo update "${CERT_MANAGER_HELM_REPO_NAME}" >/dev/null

  helm upgrade --install "${CERT_MANAGER_RELEASE}" "${CERT_MANAGER_HELM_REPO_NAME}/cert-manager" \
    --namespace "${CERT_MANAGER_NAMESPACE}" \
    --create-namespace \
    --wait \
    --timeout "${HELM_TIMEOUT}" \
    --set crds.enabled=true
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

  if [[ "${EDGE_TYPE}" == "none" ]]; then
    log "Edge type is 'none' — skipping straiker-edge entirely. Point your own ingress/LoadBalancer at straiker-frontend-service, straiker-defend, and straiker-ascend-control-plane directly."
    return
  fi

  if [[ "${EDGE_TYPE}" == "tailscale" ]]; then
    local operator_status cert_manager_status
    operator_status="$(helm status "${TAILSCALE_OPERATOR_RELEASE}" -n "${TAILSCALE_OPERATOR_NAMESPACE}" -o json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
    if [[ "${operator_status}" != "deployed" ]]; then
      mark_phase_blocked "Release '${TAILSCALE_OPERATOR_RELEASE}' in namespace '${TAILSCALE_OPERATOR_NAMESPACE}' is not healthy (status: '${operator_status:-not installed}'). straiker-edge's Service needs it to expose itself onto the tailnet — fix and re-run 'tailscale-operator' first (--phase tailscale-operator --rerun-phase)."
      return
    fi
    cert_manager_status="$(helm status "${CERT_MANAGER_RELEASE}" -n "${CERT_MANAGER_NAMESPACE}" -o json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
    if [[ "${cert_manager_status}" != "deployed" ]]; then
      mark_phase_blocked "Release '${CERT_MANAGER_RELEASE}' in namespace '${CERT_MANAGER_NAMESPACE}' is not healthy (status: '${cert_manager_status:-not installed}'). straiker-edge's Certificate needs cert-manager's CRDs/controller running — fix and re-run 'cert-manager' first (--phase cert-manager --rerun-phase)."
      return
    fi
  fi

  if [[ "${EDGE_TYPE}" == "alb" ]]; then
    # No --internal-lb-source-ranges given at capture time (see
    # capture_install_config's alb block) — resolve it here instead, now
    # that the EKS cluster actually exists to look up. Defaulting to the
    # cluster's own VPC CIDR is meaningfully narrow (not 0.0.0.0/0) and
    # naturally covers WorkSpaces Secure Browser's cross-account ENIs, which
    # get addresses from inside this VPC by construction.
    if [[ -z "$(get_metadata "internal_lb_source_ranges")" ]]; then
      require_command aws
      local vpc_id vpc_cidr
      vpc_id="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
      if [[ -n "${vpc_id}" && "${vpc_id}" != "None" ]]; then
        vpc_cidr="$(aws ec2 describe-vpcs --vpc-ids "${vpc_id}" --region "${AWS_REGION}" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || true)"
      fi
      if [[ -n "${vpc_cidr}" && "${vpc_cidr}" != "None" ]]; then
        set_metadata "internal_lb_source_ranges" "${vpc_cidr}"
        log "No --internal-lb-source-ranges given — defaulting the ALB's allowed CIDR to this cluster's own VPC (${vpc_cidr}). Pass --internal-lb-source-ranges explicitly for something narrower (e.g. a VPN's client CIDR pool)."
      else
        mark_phase_blocked "Could not auto-resolve this cluster's VPC CIDR (describe-cluster/describe-vpcs failed). Pass --internal-lb-source-ranges explicitly and re-run."
        return
      fi
    fi

    if [[ -z "$(get_metadata "custom_domain")" || -z "$(get_metadata "alb_certificate_arn")" || -z "$(get_metadata "internal_lb_source_ranges")" ]]; then
      mark_phase_blocked "Missing custom_domain/alb_certificate_arn/internal_lb_source_ranges from install state. Re-run with --edge-type alb so they're captured."
      return
    fi
  fi

  if [[ "${EDGE_TYPE}" == "xalb" ]]; then
    # No CIDR requirement here, unlike alb — xalb is genuinely public by
    # design, so there's no equivalent "default to something narrow" step.
    if [[ -z "$(get_metadata "custom_domain")" || -z "$(get_metadata "alb_certificate_arn")" ]]; then
      mark_phase_blocked "Missing custom_domain/alb_certificate_arn from install state. Re-run with --edge-type xalb so they're captured (--phase edge-infra --rerun-phase if the certificate specifically is missing)."
      return
    fi
  fi

  require_file_inputs "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"
  ensure_k8s_ready_for_charts || return

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  if [[ ( "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" ) && -z "$(get_metadata "waf_web_acl_arn")" ]]; then
    mark_phase_blocked "No AWS WAF Web ACL in install state for edge type ${EDGE_TYPE}. Re-run phase 'edge-infra' first (--phase edge-infra --rerun-phase)."
    return
  fi
  if gateway_via_alb && [[ -z "$(get_metadata "gateway_domain")" || -z "$(get_metadata "gateway_cert_arn")" ]]; then
    mark_phase_blocked "The api-gateway rides the xalb ALB but its name/certificate is not in install state. Pass --gateway-domain (or --gateway-cert-arn) and re-run phases gateway-cert, platform-services and straiker-edge."
    return
  fi

  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  local cmd=(
    helm upgrade --install "${EDGE_RELEASE}" "$(chart_ref "${EDGE_CHART_NAME}")"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --wait
    --timeout "${HELM_TIMEOUT}"
    --set "edgeType=${EDGE_TYPE}"
  )
  ha_enabled && cmd+=(--set "replicas=2")
  if [[ "${EDGE_TYPE}" == "tailscale" ]]; then
    cmd+=(--set "tailscale.domain=$(get_metadata "custom_domain")")
    cmd+=(--set "tailscale.clusterIssuerEmail=${TAILSCALE_CLUSTER_ISSUER_EMAIL:-$(get_metadata "tailscale_cluster_issuer_email")}")
    cmd+=(--set "tailscale.hostedZoneId=$(get_metadata "tailscale_hosted_zone_id")")
    cmd+=(--set "tailscale.region=${AWS_REGION}")
  fi
  if [[ "${EDGE_TYPE}" == "alb" ]]; then
    cmd+=(--set "alb.domain=$(get_metadata "custom_domain")")
    cmd+=(--set "alb.certificateArn=$(get_metadata "alb_certificate_arn")")
    local alb_cidrs
    alb_cidrs="$(get_metadata "internal_lb_source_ranges")"
    cmd+=(--set-string "alb.inboundCidrs=${alb_cidrs//,/\\,}")
    local alb_subnets
    alb_subnets="$(get_metadata "alb_subnets")"
    if [[ -n "${alb_subnets}" ]]; then
      cmd+=(--set "alb.subnets=${alb_subnets}")
    fi
  fi
  if [[ "${EDGE_TYPE}" == "alb" || "${EDGE_TYPE}" == "xalb" ]]; then
    cmd+=(--set-string "waf.webAclArn=$(get_metadata "waf_web_acl_arn")")
  fi
  if [[ "${EDGE_TYPE}" == "xalb" ]]; then
    cmd+=(--set "xalb.domain=$(get_metadata "custom_domain")")
    cmd+=(--set "xalb.certificateArn=$(get_metadata "alb_certificate_arn")")
    # The ALB's security group admits the console ranges, plus the gateway's when it rides this ALB. Ranges for only one
    # of the two cannot go here (they would shut the other out): WAF enforces them per host (phase edge-infra).
    local xalb_cidrs gw_cidrs=""
    xalb_cidrs="$(get_metadata "internal_lb_source_ranges")"
    if gateway_via_alb; then
      gw_cidrs="$(get_metadata "gateway_allowed_cidrs")"
      if [[ -n "${xalb_cidrs}" && -n "${gw_cidrs}" ]]; then
        xalb_cidrs="${xalb_cidrs},${gw_cidrs}"
      else
        xalb_cidrs=""
      fi
      cmd+=(--set-string "xalb.api.host=$(get_metadata "gateway_domain")")
      cmd+=(--set-string "xalb.api.certificateArn=$(get_metadata "gateway_cert_arn")")
    fi
    if [[ -n "${xalb_cidrs}" ]]; then
      cmd+=(--set-string "xalb.inboundCidrs=${xalb_cidrs//,/\\,}")
    fi
  fi
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
  "${cmd[@]}" || return

  # The api-gateway on the ALB: wait for the ALB's address, then point the gateway name at it.
  if gateway_via_alb; then
    local alb_host="" n
    for n in $(seq 1 30); do
      alb_host="$(kubectl get ingress "${EDGE_RELEASE}-xalb-api" -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
      [[ -n "${alb_host}" ]] && break
      sleep 10
    done
    if [[ -z "${alb_host}" ]]; then
      log "WARNING: the edge ALB has no address yet: check 'kubectl describe ingress ${EDGE_RELEASE}-xalb-api -n ${INFRA_NAMESPACE}', then re-run this phase to point $(get_metadata "gateway_domain") at it."
      return
    fi
    log "api-gateway is served by the edge ALB ${alb_host} (AWS WAF $(get_metadata "waf_web_acl_arn"))."
    gateway_dns_ensure
  fi
}

# CloudWatch for the cluster (terraform/aws/observability): the CloudWatch Observability add-on, alarms and their SNS
# topic. Runs last so the edge ALB exists (its alarms need the ALB's ARN). Re-run it after the edge or the data tier
# changes. EKS only.
phase_observability() {
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    set_phase_status "${CURRENT_PHASE}" "skipped" "CloudWatch is AWS-only."
    return
  fi
  require_command aws
  require_command tofu
  require_terraform_dir "${OBSERVABILITY_SRC}" || return
  sync_terraform_workdir "${OBSERVABILITY_SRC}" "${OBSERVABILITY_DIR}"

  local bucket_name
  bucket_name="$(get_metadata "bootstrap_bucket")"
  [[ -n "${bucket_name}" ]] || bucket_name="$(resolve_bucket_name)"
  if ! aws s3api head-bucket --bucket "${bucket_name}" >/dev/null 2>&1; then
    mark_phase_blocked "Bootstrap bucket '${bucket_name}' not found. Run phase 'eks-tfbe' first."
    return
  fi
  if ! aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent --region "${AWS_REGION}" >/dev/null 2>&1; then
    mark_phase_blocked "The EKS add-on eks-pod-identity-agent is not installed on '${CLUSTER_NAME}' (the CloudWatch agent authenticates through Pod Identity). Add it: aws eks create-addon --cluster-name ${CLUSTER_NAME} --addon-name eks-pod-identity-agent --region ${AWS_REGION}"
    return
  fi
  write_observability_backend_config "${bucket_name}"

  # Alarm subscribers: remembered, new ones added.
  local emails
  emails="$(printf '%s,%s' "$(get_metadata "alarm_emails")" "${ALARM_EMAILS}" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort -u | paste -sd, - || true)"
  set_metadata "alarm_emails" "${emails}"

  # The edge ALB (alb/xalb), found by its Ingress's address.
  local alb_suffix="" ingress="" alb_dns alb_arn
  case "${EDGE_TYPE}" in
    xalb) ingress="${EDGE_RELEASE}-xalb-frontend" ;;
    alb) ingress="${EDGE_RELEASE}-alb" ;;
  esac
  if [[ -n "${ingress}" ]]; then
    alb_dns="$(kubectl get ingress "${ingress}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "${alb_dns}" ]]; then
      alb_arn="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" --query "LoadBalancers[?DNSName=='${alb_dns}'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)"
      [[ "${alb_arn}" == arn:* ]] && alb_suffix="${alb_arn#*:loadbalancer/}"
    fi
    [[ -n "${alb_suffix}" ]] || log "WARNING: edge ALB not found (Ingress ${ingress} has no address yet): no ALB alarms. Re-run this phase once it exists."
  fi

  # Aurora clusters of this install: "<cluster>-aurora" and "<cluster>-aurora-<key>".
  local aurora_json
  aurora_json="$(aws rds describe-db-clusters --region "${AWS_REGION}" --query 'DBClusters[].DBClusterIdentifier' --output json 2>/dev/null \
    | CLUSTER="${CLUSTER_NAME}" python3 -c '
import json, os, sys
c = os.environ["CLUSTER"] + "-aurora"
ids = json.load(sys.stdin) if sys.stdin.readable() else []
print(json.dumps(sorted(i for i in ids if i == c or i.startswith(c + "-"))))
' 2>/dev/null || echo '[]')"

  local emails_json
  emails_json="$(EMAILS="${emails}" python3 -c 'import json,os; print(json.dumps([e for e in os.environ["EMAILS"].split(",") if e]))')"

  tofu_init "${OBSERVABILITY_DIR}" -upgrade -input=false -migrate-state -force-copy
  local tf_vars=(
    -var="region=${AWS_REGION}"
    -var="cluster_name=${CLUSTER_NAME}"
    -var="alb_arn_suffix=${alb_suffix}"
    -var="aurora_cluster_ids=${aurora_json}"
    -var="alarm_emails=${emails_json}"
  )

  # Adopt what already exists outside this state (log groups the agent created, an add-on installed by hand), so the
  # apply manages them instead of failing on "already exists".
  local state g
  state="$(tofu -chdir="${OBSERVABILITY_DIR}" state list 2>/dev/null || true)"
  for g in application dataplane host performance; do
    if ! grep -qF "aws_cloudwatch_log_group.container_insights[\"${g}\"]" <<<"${state}" \
      && [[ "$(aws logs describe-log-groups --region "${AWS_REGION}" --log-group-name-prefix "/aws/containerinsights/${CLUSTER_NAME}/${g}" \
        --query "logGroups[?logGroupName=='/aws/containerinsights/${CLUSTER_NAME}/${g}'] | length(@)" --output text 2>/dev/null)" == "1" ]]; then
      log "Adopting existing log group /aws/containerinsights/${CLUSTER_NAME}/${g}."
      tofu -chdir="${OBSERVABILITY_DIR}" import -input=false "${tf_vars[@]}" \
        "aws_cloudwatch_log_group.container_insights[\"${g}\"]" "/aws/containerinsights/${CLUSTER_NAME}/${g}"
    fi
  done
  if ! grep -qF 'aws_eks_addon.cloudwatch_observability' <<<"${state}" \
    && aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name amazon-cloudwatch-observability --region "${AWS_REGION}" >/dev/null 2>&1; then
    log "Adopting the existing amazon-cloudwatch-observability add-on."
    tofu -chdir="${OBSERVABILITY_DIR}" import -input=false "${tf_vars[@]}" \
      aws_eks_addon.cloudwatch_observability "${CLUSTER_NAME}:amazon-cloudwatch-observability"
  fi

  tofu -chdir="${OBSERVABILITY_DIR}" apply -auto-approve -input=false "${tf_vars[@]}"

  local topic
  topic="$(tofu -chdir="${OBSERVABILITY_DIR}" output -raw alarm_topic_arn 2>/dev/null || true)"
  set_metadata "alarm_topic_arn" "${topic}"
  log "CloudWatch: Container Insights on, container logs in /aws/containerinsights/${CLUSTER_NAME}/application, alarms -> ${topic}."
  if [[ -n "${emails}" ]]; then
    log "MANUAL STEP: each alarm address (${emails}) gets an 'AWS Notification - Subscription Confirmation' mail; alarms reach it only after the link in it is clicked."
  else
    log "No --alarm-email given: alarms go to ${topic} with no subscriber. Re-run this phase with --alarm-email <address>, or subscribe any endpoint to the topic."
  fi
}

# Called unconditionally at the end of a successful main() run — not just
# right after phase_straiker_edge actually executes, since that phase gets
# skipped entirely on a re-run once already marked done. Reads live cluster
# state rather than assuming anything was just installed, so it prints
# correctly whether this run did real work or everything was already up from
# a previous one.
show_access_info() {
  if [[ "${EDGE_TYPE}" == "none" ]]; then
    local custom_domain
    custom_domain="$(get_metadata "custom_domain")"
    log ""
    if [[ -n "${custom_domain}" ]]; then
      log "Straiker is installed. Edge type is 'none' — OIDC/CORS are configured for:"
      log "  Frontend : https://$(custom_domain_hostname straiker)/"
      log "  Defend   : https://$(custom_domain_hostname straiker-defend)/"
      log "  Ascend   : https://$(custom_domain_hostname straiker-ascend)/"
      log ""
      log "No ingress was installed for these hostnames — point your own"
      log "ingress/LoadBalancer at these ClusterIP Services (namespace ${INFRA_NAMESPACE}):"
      log "  straiker-frontend-service:80, straiker-defend:80, straiker-ascend-control-plane:80"
    else
      log "Straiker is installed. Edge type is 'none' — no ingress was installed for you."
      log "Point your own ingress/LoadBalancer at these ClusterIP Services (namespace ${INFRA_NAMESPACE}):"
      log "  Frontend : straiker-frontend-service:80"
      log "  Defend   : straiker-defend:80"
      log "  Ascend   : straiker-ascend-control-plane:80"
    fi
    return
  fi

  if [[ "${EDGE_TYPE}" == "alb" ]]; then
    local custom_domain
    custom_domain="$(get_metadata "custom_domain")"
    log ""
    log "Straiker is installed. Edge type is 'alb' — reachable at:"
    log "  Frontend : https://$(custom_domain_hostname straiker)/"
    log "  Defend   : https://$(custom_domain_hostname straiker-defend)/"
    log "  Ascend   : https://$(custom_domain_hostname straiker-ascend)/"
    log ""
    if [[ "$(get_metadata "alb_route53_automation")" == "true" ]]; then
      log "Certificate is real and DNS-validated — no browser trust warning."
    fi
    log "Find the ALB's DNS name with:"
    log "  kubectl get ingress -n ${INFRA_NAMESPACE} ${EDGE_RELEASE}-alb"
    log "then point ${custom_domain}'s DNS at it (Route53 ALIAS record, or however"
    log "you manage that zone — this installer doesn't sync it automatically for"
    log "alb, unlike xalb with --xalb-route53, since alb has no public DNS record"
    log "for ExternalDNS to manage). Reachability from WorkSpaces Secure Browser (or"
    log "whatever's on the other end) depends on its network having a path to this"
    log "ALB's subnets — confirm that separately."
    local bastion_id
    bastion_id="$(get_metadata "alb_bastion_instance_id")"
    if [[ -n "${bastion_id}" ]]; then
      log ""
      log "Verification bastion '${bastion_id}' is available. Connect with:"
      log "  aws ssm start-session --target ${bastion_id} --document-name AWS-StartPortForwardingSessionToRemoteHost \\"
      log "    --parameters '{\"host\":[\"<alb-dns-name>\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}'"
      log "then browse to https://localhost:8443 (real certificate — no browser warning to expect)."
    fi
    return
  fi

  if [[ "${EDGE_TYPE}" == "xalb" ]]; then
    local custom_domain
    custom_domain="$(get_metadata "custom_domain")"
    log ""
    log "Straiker is installed. Edge type is 'xalb' — reachable at:"
    log "  Frontend : https://$(custom_domain_hostname straiker)/"
    log "  Defend   : https://$(custom_domain_hostname straiker-defend)/"
    log "  Ascend   : https://$(custom_domain_hostname straiker-ascend)/"
    if gateway_via_alb; then
      log "  API      : https://$(get_metadata "gateway_domain")/  (api-gateway: SDKs, agents, Detect API; same ALB)"
    fi
    log "AWS WAF  : $(get_metadata "waf_web_acl_arn")"
    log "           request logs in CloudWatch Logs group $(get_metadata "waf_log_group")"
    log ""
    if [[ "$(get_metadata "xalb_route53_automation")" == "true" ]]; then
      log "Certificate is real and DNS-validated — no browser trust warning."
      log "DNS is managed automatically by ExternalDNS — the above hostnames should"
      log "resolve on their own once the controller has synced (usually under a minute)."
    else
      log "Using the certificate from --alb-certificate-arn. Point ${custom_domain}'s"
      log "DNS at the ALB yourself (Route53 ALIAS record, or however you manage that"
      log "zone). Find its DNS name with:"
      log "  kubectl get ingress -n ${INFRA_NAMESPACE} ${EDGE_RELEASE}-xalb-frontend"
    fi
    return
  fi

  if [[ "${EDGE_TYPE}" == "tailscale" ]]; then
    log ""
    log "Straiker is installed. Edge type is 'tailscale' — once you complete the"
    log "one-time Tailscale-side setup in examples/edge/tailscale.md (custom DNS"
    log "records pointing your hostnames at the IP below), reachable at:"
    log "  Frontend : https://$(custom_domain_hostname straiker)/"
    log "  Defend   : https://$(custom_domain_hostname straiker-defend)/"
    log "  Ascend   : https://$(custom_domain_hostname straiker-ascend)/"
    log ""
    log "Certificate is real (Let's Encrypt via cert-manager/Route53 DNS-01) — no"
    log "browser trust warning, once the certificate has finished issuing"
    log "(usually 1-3 minutes after the first apply)."
    log ""
    local tailnet_hostname
    tailnet_hostname="$(kubectl get svc "${EDGE_RELEASE}" -n "${INFRA_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "${tailnet_hostname}" ]]; then
      log "Tailscale hostname for the straiker-edge Service: ${tailnet_hostname}"
      log "Point your custom DNS records at this (or its IP, from the Tailscale admin"
      log "console's machine list) — see examples/edge/tailscale.md."
    else
      log "Find the Tailscale machine for the straiker-edge Service in your Tailscale"
      log "admin console's machine list (or: kubectl get svc ${EDGE_RELEASE} -n ${INFRA_NAMESPACE})"
      log "and point your custom DNS records at its IP — see examples/edge/tailscale.md."
    fi
    return
  fi

  local caddyfile edge_port
  caddyfile="$(kubectl -n "${INFRA_NAMESPACE}" get configmap straiker-edge-config -o jsonpath='{.data.Caddyfile}' 2>/dev/null || true)"

  # Extract the shared edge port from the first site block.
  edge_port="$(printf '%s' "${caddyfile}" | grep -o '[^ {]*:[0-9]*' | head -1 | cut -d: -f2 || true)"
  edge_port="${edge_port:-8443}"

  # Collect routed hostnames; fall back to well-known defaults.
  local app_host defend_host ascend_host
  app_host="$(printf '%s'    "${caddyfile}" | grep -o 'app\.[^ {:]*'    | head -1 || true)"
  defend_host="$(printf '%s' "${caddyfile}" | grep -o 'defend\.[^ {:]*' | head -1 || true)"
  ascend_host="$(printf '%s' "${caddyfile}" | grep -o 'ascend\.[^ {:]*' | head -1 || true)"
  [[ -n "${app_host}" ]]    || app_host="app.straiker.internal"
  [[ -n "${defend_host}" ]] || defend_host="defend.straiker.internal"
  [[ -n "${ascend_host}" ]] || ascend_host="ascend.straiker.internal"

  log ""
  log "Straiker is installed. To reach it from your machine:"
  log ""
  log "  1. Add all hosts to /etc/hosts (one line):"
  log "       echo '127.0.0.1  ${app_host} ${defend_host} ${ascend_host}' | sudo tee -a /etc/hosts"
  log ""
  log "  2. Start a port-forward to the edge:"
  log "       kubectl -n ${INFRA_NAMESPACE} port-forward svc/straiker-edge ${edge_port}:${edge_port}"
  log ""
  log "  3. Open the dashboard (self-signed cert warning expected):"
  log "       https://${app_host}:${edge_port}/"
  log ""
  log "  Ascend : https://${ascend_host}:${edge_port}/"
  log "  Defend : https://${defend_host}:${edge_port}/"
  log ""
  log "Smoke test the Defend API (needs one of your application's API keys):"
  log "  curl -sk -X POST https://${defend_host}:${edge_port}/api/v1/detect \\"
  log "    -H \"Authorization: <api-key>\" \\"
  log "    -H \"Content-Type: application/json\" \\"
  log "    -H \"Straiker-Debug: true\" \\"
  log "    -d '{\"prompt\":\"What is the capital of France?\"}' | jq"
  if [[ -n "$(get_metadata "gateway_domain")" && "$(get_metadata "gateway_exposure")" == "public" ]]; then
    log ""
    log "API gateway (SDK / agents): https://$(get_metadata "gateway_domain")   (TLS: $(get_metadata "gateway_cert_source" | sed 's/own/your ACM certificate/;s/issued/ACM certificate issued by the installer/'))"
    if [[ -n "$(get_metadata "gateway_dns_record")" ]]; then
      log "  DNS still to add: $(get_metadata "gateway_dns_record")"
    fi
  fi
}

# Reminder printed at the end of every successful run — the bootstrap admin
# (see phase_shared_secrets/phase_straiker_core) always exists whichever
# edge type was used, so this runs unconditionally rather than living inside
# show_access_info's per-edge-type branches. Doesn't print the plaintext
# password itself — same reasoning as elsewhere in this script, no secret
# material goes into terminal scrollback/log files that don't need it;
# ops fetch it themselves when ready to log in.
show_bootstrap_admin_reminder() {
  if [[ -n "$(get_metadata "cognito_pool_id")" ]]; then
    log ""
    log "Login is Amazon Cognito (user pool $(get_metadata "cognito_pool_id")). First admin: $(get_metadata "admin_email")."
    log "Its password is in Secrets Manager; retrieve it with:"
    log "  aws secretsmanager get-secret-value --secret-id $(get_metadata "cognito_admin_secret_name") --region ${AWS_REGION} --query SecretString --output text"
    if [[ -n "$(get_metadata "sso_name")" ]]; then
      log "SSO provider '$(get_metadata "sso_name")' ($(get_metadata "sso_type")) is federated into the pool for: $(get_metadata "sso_domains")."
    fi
    if [[ -n "$(get_metadata "sso_handoff_file")" ]]; then
      log "Setup sheet for the customer's identity provider admin (no secrets): $(get_metadata "sso_handoff_file")"
    fi
    log "Add or change the SSO provider: re-run phases aws-data and straiker-core with the --sso-* flags."
    if [[ -n "$(get_metadata "ses_domain")" ]]; then
      log "Email: SES domain $(get_metadata "ses_domain") (sender $(get_metadata "ses_sender"))."
      if [[ -n "$(get_metadata "ses_name_servers")" ]]; then
        log "  A Route53 zone was created for it: add these NS records for $(get_metadata "ses_domain") in the parent zone: $(get_metadata "ses_name_servers")"
      fi
      log "  SES starts in the sandbox: request production access in the SES console to mail unverified recipients."
    fi
    if [[ -n "$(get_metadata "ses_existing_arn")" ]]; then
      log "Email: the customer's SES identity $(get_metadata "ses_existing_arn") (From $(get_metadata "ses_from"))."
      log "  Its account must have SES production access (out of the sandbox) to mail unverified recipients."
    fi
    log "Add more users by creating them in the pool (aws cognito-idp admin-create-user ...) and in Straiker's"
    log "Users page. If you are ever locked out, re-run phase straiker-core with --reset-admin-password."
    return
  fi
  log ""
  log "Bootstrap admin login: admin@straiker.internal — a random password was"
  log "generated for this install. Retrieve it with:"
  log "  kubectl get secret ${SHARED_SECRETS_NAME} -n ${INFRA_NAMESPACE} -o jsonpath='{.data.BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d; echo"
  log ""
  log "Once you can log in, onboard a real admin (a local account through the UI,"
  log "or your own configured OIDC IdP), then delete the bootstrap admin's user"
  log "account from within Straiker itself so it can no longer reach the product."
  log "Its dex-level static login can't be deleted outright (dex treats"
  log "staticPasswords entries as read-only) — only fully disabled, via a normal"
  log "install with --values setting straiker-frontend.dex.staticAdminEnabled: false."
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

  # Edge type — how straiker-edge exposes app/defend/ascend externally.
  # Asked first since it's independent of every other choice below. Safe to
  # change on a later run (see EDGE_TYPE declaration up top), unlike
  # cloud_provider immediately below.
  if [[ -z "${EDGE_TYPE}" ]]; then
    EDGE_TYPE="$(get_metadata "edge_type")"
  fi
  if [[ -z "${EDGE_TYPE}" ]]; then
    cat >&2 <<'EOF'

How should straiker-edge expose app/defend/ascend externally?
  1) internal          — Caddy reverse proxy with self-signed certs.
                          Reachable via 'kubectl port-forward' — see the
                          access instructions printed at the end of this
                          install.
  2) none               — install nothing; bring your own ingress/
                          LoadBalancer pointed at the frontend/defend/ascend
                          Services directly (default on GKE).
  3) tailscale          — same Caddy as internal, but with a real
                          cert-manager/Let's Encrypt certificate for your
                          own domain, and its Service exposed onto your own
                          Tailscale tailnet at L3 via the Tailscale
                          Kubernetes operator. Requires a Tailscale OAuth
                          client scoped to tag:k8s-operator, created by hand
                          in the Tailscale admin console first (see
                          examples/edge/tailscale.md) — you'll be prompted
                          for its client ID/secret next.
  4) alb                — one Ingress covering all routes via host-based
                          rules, backed by a single internal AWS
                          Application Load Balancer. For customers with no
                          public internet access (e.g. reached via
                          WorkSpaces Secure Browser). The AWS Load Balancer
                          Controller itself is installed automatically
                          unless one is already present on this cluster.
                          Requires --alb-certificate-arn unless --alb-route53
                          is passed (auto-issues one instead) — no
                          self-signed fallback either way. The allowed CIDR
                          defaults to this cluster's own VPC unless you pass
                          --internal-lb-source-ranges.
  5) xalb               — (default on EKS) same as alb, but internet-facing,
                          behind AWS WAF, also carrying the api-gateway, and sharing an
                          ALB with other Ingresses on this cluster
                          (IngressGroup) instead of getting its own.
                          Requires --alb-certificate-arn by default, same as
                          alb — works regardless of which AWS account or DNS
                          provider hosts your domain's zone. If that zone
                          happens to be in this same AWS account, pass
                          --xalb-route53 instead to auto-issue+validate a
                          real ACM certificate and keep the app hostnames
                          synced via ExternalDNS, with no ARN needed.
EOF
    # EKS default: xalb (an AWS ALB with ACM and WAF, the reference architecture). GKE has no ALB: none.
    local edge_type_answer edge_type_default=none
    [[ "${CLOUD_PROVIDER}" != "gke" ]] && edge_type_default=xalb
    edge_type_answer="$(prompt_line "Edge type [internal/none/tailscale/alb/xalb] (default: ${edge_type_default}): " || true)"
    [[ -z "${edge_type_answer}" ]] && edge_type_answer="${edge_type_default}"
    case "${edge_type_answer}" in
      1|internal) EDGE_TYPE=internal ;;
      2|none) EDGE_TYPE=none ;;
      3|tailscale) EDGE_TYPE=tailscale ;;
      4|alb) EDGE_TYPE=alb ;;
      5|xalb) EDGE_TYPE=xalb ;;
      *)
        echo "ERROR: Edge type must be 'internal', 'none', 'tailscale', 'alb', or 'xalb', got '${edge_type_answer}'." >&2
        exit 1
        ;;
    esac
  fi
  set_metadata "edge_type" "${EDGE_TYPE}"

  if [[ "${EDGE_TYPE}" == "none" ]]; then
    if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
      if [[ "$(get_metadata "custom_domain_set")" == "true" ]]; then
        CUSTOM_ORIGIN_DOMAIN="$(get_metadata "custom_domain")"
      else
        cat >&2 <<'EOF'

Since edge type is 'none', straiker-core's/straiker-ascend's OIDC redirect
URIs and CORS origin still need to match wherever you actually route
frontend/defend/ascend to (your own ingress/LoadBalancer) — otherwise Dex's
login will loop. If you already know that domain, enter it now and this
installer will set those overrides for you (straiker.<domain>,
straiker-defend.<domain>, straiker-ascend.<domain>). Leave blank to set
them yourself later via --values.
EOF
        CUSTOM_ORIGIN_DOMAIN="$(prompt_line "Custom origin domain (e.g. acmecorp.com; blank to skip): " || true)"
      fi
    fi
    set_metadata "custom_domain" "${CUSTOM_ORIGIN_DOMAIN}"
    set_metadata "custom_domain_set" "true"
  fi

  if [[ "${EDGE_TYPE}" == "alb" ]]; then
    if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
      CUSTOM_ORIGIN_DOMAIN="$(get_metadata "custom_domain")"
    fi
    if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
      cat >&2 <<'EOF'

Edge type 'alb' needs the domain frontend/defend/ascend will be reachable
at — it drives both the ALB's Ingress host rules and straiker-core's/
straiker-ascend's OIDC redirect URIs/CORS origin (straiker.<domain>,
straiker-defend.<domain>, straiker-ascend.<domain>).
EOF
      CUSTOM_ORIGIN_DOMAIN="$(prompt_line "Custom origin domain (e.g. acmecorp.com): " || true)"
      if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
        echo "ERROR: Edge type 'alb' requires a domain. Set CUSTOM_ORIGIN_DOMAIN in this shell, or re-run and answer the prompt." >&2
        exit 1
      fi
    fi
    set_metadata "custom_domain" "${CUSTOM_ORIGIN_DOMAIN}"

    # No question asked here either — Route53 automation (a real
    # DNS-validated certificate, no --alb-certificate-arn needed) is opt-in
    # via --alb-route53, off by default. Off is what works regardless of
    # which AWS account/DNS provider hosts the domain's zone (bring your own
    # ARN); on is a convenience only for the common case where that zone is
    # in this same AWS account. Same mechanism/reasoning as xalb's
    # XALB_ROUTE53_AUTOMATION below, just without ExternalDNS (alb is
    # internal-only, no public DNS record to keep synced).
    if [[ -z "${ALB_ROUTE53_AUTOMATION}" ]]; then
      ALB_ROUTE53_AUTOMATION="$(get_metadata "alb_route53_automation")"
    fi
    if [[ -z "${ALB_ROUTE53_AUTOMATION}" ]]; then
      ALB_ROUTE53_AUTOMATION=false
    fi
    set_metadata "alb_route53_automation" "${ALB_ROUTE53_AUTOMATION}"

    if [[ "${ALB_ROUTE53_AUTOMATION}" != "true" ]]; then
      if [[ -z "${ALB_CERTIFICATE_ARN}" ]]; then
        ALB_CERTIFICATE_ARN="$(get_metadata "alb_certificate_arn")"
      fi
      if [[ -z "${ALB_CERTIFICATE_ARN}" ]]; then
        echo "ERROR: Edge type 'alb' requires --alb-certificate-arn unless --alb-route53 is passed (auto-issues one instead, only works when the domain's Route53 zone is in this AWS account). Request one via DNS validation and pass its ARN, or pass --alb-route53 if the zone is here." >&2
        exit 1
      fi
      set_metadata "alb_certificate_arn" "${ALB_CERTIFICATE_ARN}"
    fi

    # No question asked here either — the bastion is purely an optional,
    # opt-in verification convenience (see phase_edge_infra); pass
    # --alb-provision-bastion explicitly if you want one.
    set_metadata "alb_provision_bastion" "${ALB_PROVISION_BASTION:-false}"

    # No question asked here either. Unlike a bare 0.0.0.0/0 fallback (which
    # would open this up to anything that can route to the VPC — peered
    # VPCs, VPNs, Transit Gateway, the broader corporate network), defaulting
    # to the VPC's OWN CIDR is a meaningfully narrow, safe default: it's
    # naturally inclusive of WorkSpaces Secure Browser's cross-account ENIs
    # (which get addresses from inside this VPC by construction) without
    # requiring the installer to know anything about WSB specifically. Actual
    # resolution happens in phase_straiker_edge (needs the live EKS cluster
    # to look up its VPC, which may not exist yet at this point in a fresh
    # --install-eks run). Pass --internal-lb-source-ranges explicitly for
    # anything narrower (e.g. just a VPN's client CIDR pool).
    if [[ -n "${INTERNAL_LB_SOURCE_RANGES}" ]]; then
      set_metadata "internal_lb_source_ranges" "${INTERNAL_LB_SOURCE_RANGES}"
    fi

    if [[ -z "${ALB_SUBNETS}" ]]; then
      ALB_SUBNETS="$(get_metadata "alb_subnets")"
    fi
    if [[ -z "${ALB_SUBNETS}" && "$(get_metadata "alb_subnets_set")" != "true" ]]; then
      cat >&2 <<'EOF'

Comma-separated subnet IDs for the ALB, or blank to rely on the AWS Load
Balancer Controller's subnet auto-discovery
(kubernetes.io/role/internal-elb=1 tag on private subnets).
EOF
      ALB_SUBNETS="$(prompt_line "Subnet IDs (blank for auto-discovery): " || true)"
    fi
    set_metadata "alb_subnets" "${ALB_SUBNETS}"
    set_metadata "alb_subnets_set" "true"
  fi

  if [[ "${EDGE_TYPE}" == "tailscale" ]]; then
    if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
      CUSTOM_ORIGIN_DOMAIN="$(get_metadata "custom_domain")"
    fi
    if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
      cat >&2 <<'EOF'

Edge type 'tailscale' needs the domain frontend/defend/ascend will be
reachable at — it drives the Let's Encrypt certificate's SANs and
straiker-core's/straiker-ascend's OIDC redirect URIs/CORS origin
(straiker.<domain>, straiker-defend.<domain>, straiker-ascend.<domain>).
The Route53 zone for this domain must already exist in this AWS account
(cert-manager's DNS-01 solver needs to write a challenge TXT record there).
EOF
      CUSTOM_ORIGIN_DOMAIN="$(prompt_line "Custom origin domain (e.g. acmecorp.com): " || true)"
      if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
        echo "ERROR: Edge type 'tailscale' requires a domain. Set CUSTOM_ORIGIN_DOMAIN in this shell, or re-run and answer the prompt." >&2
        exit 1
      fi
    fi
    set_metadata "custom_domain" "${CUSTOM_ORIGIN_DOMAIN}"
  fi

  if [[ "${EDGE_TYPE}" == "xalb" ]]; then
    if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
      CUSTOM_ORIGIN_DOMAIN="$(get_metadata "custom_domain")"
    fi
    if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
      cat >&2 <<'EOF'

Edge type 'xalb' needs the domain frontend/defend/ascend will be reachable
at — it drives the ALB's Ingress host rules, the DNS-validated
certificate's SANs, and straiker-core's/straiker-ascend's OIDC redirect
URIs/CORS origin (straiker.<domain>, straiker-defend.<domain>,
straiker-ascend.<domain>). The Route53 zone for this domain must already
exist in this AWS account.
EOF
      CUSTOM_ORIGIN_DOMAIN="$(prompt_line "Custom origin domain (e.g. acmecorp.com): " || true)"
      if [[ -z "${CUSTOM_ORIGIN_DOMAIN}" ]]; then
        echo "ERROR: Edge type 'xalb' requires a domain. Set CUSTOM_ORIGIN_DOMAIN in this shell, or re-run and answer the prompt." >&2
        exit 1
      fi
    fi
    set_metadata "custom_domain" "${CUSTOM_ORIGIN_DOMAIN}"

    # No question asked here either — Route53 automation (a real
    # DNS-validated certificate + ExternalDNS keeping the app hostnames
    # synced) is opt-in via --xalb-route53, off by default. Off is what
    # works regardless of which AWS account/DNS provider hosts the domain's
    # zone (bring your own --alb-certificate-arn, manage DNS yourself); on
    # is a convenience only for the common case where that zone is in this
    # same AWS account. No self-signed fallback either way.
    if [[ -z "${XALB_ROUTE53_AUTOMATION}" ]]; then
      XALB_ROUTE53_AUTOMATION="$(get_metadata "xalb_route53_automation")"
    fi
    if [[ -z "${XALB_ROUTE53_AUTOMATION}" ]]; then
      XALB_ROUTE53_AUTOMATION=false
    fi
    set_metadata "xalb_route53_automation" "${XALB_ROUTE53_AUTOMATION}"

    if [[ "${XALB_ROUTE53_AUTOMATION}" != "true" ]]; then
      if [[ -z "${ALB_CERTIFICATE_ARN}" ]]; then
        ALB_CERTIFICATE_ARN="$(get_metadata "alb_certificate_arn")"
      fi
      if [[ -z "${ALB_CERTIFICATE_ARN}" ]]; then
        echo "ERROR: Edge type 'xalb' requires --alb-certificate-arn unless --xalb-route53 is passed (auto-issues one instead, only works when the domain's Route53 zone is in this AWS account). Request one via DNS validation and pass its ARN, or pass --xalb-route53 if the zone is here." >&2
        exit 1
      fi
      set_metadata "alb_certificate_arn" "${ALB_CERTIFICATE_ARN}"
    fi
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

  # API server exposure + NAT topology. First-run-only for the reasons given
  # at CLUSTER_PUBLIC_ACCESS's declaration: silently re-exposing a control
  # plane, or silently changing the egress IP a customer's firewall pins, are
  # both changes nobody would think to look for in an -auto-approve apply.
  # Not prompted interactively -- both are deliberate, network-dependent
  # choices that need the operator to already know their routing story, and
  # the defaults (public endpoint, NAT per provision_strategy) are correct for
  # the common case.
  if [[ "${INSTALL_EKS}" == true && "${CLOUD_PROVIDER}" != "gke" ]]; then
    if [[ "$(get_metadata "cluster_endpoint_set")" == "true" ]]; then
      CLUSTER_PUBLIC_ACCESS="$(get_metadata "cluster_public_access")"
      CLUSTER_PUBLIC_ACCESS_CIDRS="$(get_metadata "cluster_public_access_cidrs")"
      CLUSTER_API_ALLOWED_CIDRS="$(get_metadata "cluster_api_allowed_cidrs")"
    elif [[ "${CLUSTER_ENDPOINT_EXPLICIT}" == true ]]; then
      # A private-only endpoint with no allowed CIDRs is unreachable from
      # anywhere except the nodes themselves -- catch it here rather than
      # after a 15-minute apply that ends in a cluster nobody can kubectl to.
      if [[ "${CLUSTER_PUBLIC_ACCESS}" == false && -z "${CLUSTER_API_ALLOWED_CIDRS}" ]]; then
        echo "ERROR: --private-api-endpoint needs --api-allowed-cidrs <cidrs> — the CIDRs your operators reach the VPC from (Transit Gateway/Direct Connect/VPN). Without it the Kubernetes API is reachable from nothing but the cluster's own nodes." >&2
        exit 1
      fi
      set_metadata "cluster_public_access" "${CLUSTER_PUBLIC_ACCESS}"
      set_metadata "cluster_public_access_cidrs" "${CLUSTER_PUBLIC_ACCESS_CIDRS}"
      set_metadata "cluster_api_allowed_cidrs" "${CLUSTER_API_ALLOWED_CIDRS}"
      set_metadata "cluster_endpoint_set" "true"
    fi

    if [[ "$(get_metadata "single_nat_gateway_set")" == "true" ]]; then
      SINGLE_NAT_GATEWAY="$(get_metadata "single_nat_gateway")"
    elif [[ "${SINGLE_NAT_GATEWAY_EXPLICIT}" == true ]]; then
      set_metadata "single_nat_gateway" "${SINGLE_NAT_GATEWAY}"
      set_metadata "single_nat_gateway_set" "true"
    fi
  fi

  # Bring-your-own-VPC — only meaningful for AWS EKS provisioning (no GKE
  # equivalent exists yet). First-run-only like provision_strategy above:
  # once persisted, always wins regardless of what --vpc-id says on a later
  # invocation (switching VPCs mid-install isn't a thing this installer
  # supports, same reasoning as cloud_provider/provision_strategy).
  if [[ "${INSTALL_EKS}" == true && "${CLOUD_PROVIDER}" != "gke" ]]; then
    if [[ "$(get_metadata "vpc_id_set")" == "true" ]]; then
      VPC_ID="$(get_metadata "vpc_id")"
      PRIVATE_SUBNET_IDS="$(get_metadata "private_subnet_ids")"
      PUBLIC_SUBNET_IDS="$(get_metadata "public_subnet_ids")"
    else
      if [[ -z "${VPC_ID}" ]]; then
        cat >&2 <<'EOF'

Provision a new VPC, or attach to an existing one?
  new (default) — this installer creates and manages its own VPC/subnets.
  existing      — bring your own VPC (e.g. your AWS account's SCP denies
                  ec2:CreateVpc). Your subnets must already have outbound
                  internet routing (NAT/IGW) — this installer does not
                  create one in this mode.
EOF
        local vpc_answer
        vpc_answer="$(prompt_line 'VPC [new/existing] (default: new): ' || true)"
        if [[ "${vpc_answer}" == "existing" ]]; then
          VPC_ID="$(prompt_line 'Existing VPC ID: ' || true)"
          PRIVATE_SUBNET_IDS="$(prompt_line 'Private subnet IDs, comma-separated (>=2, one per AZ; order matters under provision_strategy=min — only the first is used): ' || true)"
          PUBLIC_SUBNET_IDS="$(prompt_line 'Public subnet IDs, comma-separated: ' || true)"
          if [[ -z "${VPC_ID}" || -z "${PRIVATE_SUBNET_IDS}" || -z "${PUBLIC_SUBNET_IDS}" ]]; then
            echo "ERROR: bring-your-own-VPC needs a VPC ID and both subnet ID lists." >&2
            exit 1
          fi
        fi
      fi
      set_metadata "vpc_id" "${VPC_ID}"
      set_metadata "private_subnet_ids" "${PRIVATE_SUBNET_IDS}"
      set_metadata "public_subnet_ids" "${PUBLIC_SUBNET_IDS}"
      set_metadata "vpc_id_set" "true"
    fi

    # Normalize once here (covers both the metadata-loaded and freshly-set
    # branches above) so every later consumer — the preflight check and
    # write_eks_tfvars's tfvars generation — can trust these are already
    # trimmed with no empty entries. A stray leading/trailing/doubled comma
    # here previously produced an empty string list element that sailed
    # straight through to `tofu apply`, where it surfaced as a cryptic
    # "InvalidID: The ID '' is not valid" deep inside an aws_ec2_tag
    # resource instead of a clear error at input-resolution time.
    if [[ -n "${VPC_ID}" ]]; then
      PRIVATE_SUBNET_IDS="$(normalize_subnet_ids "${PRIVATE_SUBNET_IDS}" "--private-subnet-ids")"
      PUBLIC_SUBNET_IDS="$(normalize_subnet_ids "${PUBLIC_SUBNET_IDS}" "--public-subnet-ids")"
      set_metadata "private_subnet_ids" "${PRIVATE_SUBNET_IDS}"
      set_metadata "public_subnet_ids" "${PUBLIC_SUBNET_IDS}"
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
  validate_cluster_name # also covers a name taken from the kubectl context or the remembered state
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

  # Tailscale credentials/config for edgeType=tailscale — always
  # bring-your-own now (no more shared-tailnet mode, so no dependency on
  # STRAIKER_CUSTOMER_NAME/KEY here).
  if [[ "${EDGE_TYPE}" == "tailscale" ]]; then
    if secret_key_exists "TAILSCALE_OAUTH_CLIENT_ID" && secret_key_exists "TAILSCALE_OAUTH_CLIENT_SECRET"; then
      log "Tailscale OAuth client already present in '${SHARED_SECRETS_NAME}' — leaving as-is."
    else
      cat >&2 <<'EOF'

Tailscale edge type needs the OAuth client ID/secret from the client you
created in the Tailscale admin console (Settings/Trust credentials → OAuth
clients), scoped to tag:k8s-operator — see examples/edge/tailscale.md.
Checking this shell's environment for
TAILSCALE_OAUTH_CLIENT_ID/TAILSCALE_OAUTH_CLIENT_SECRET first — if either is
already set, it's used automatically, no prompt needed.
EOF
      TAILSCALE_OAUTH_CLIENT_ID="${TAILSCALE_OAUTH_CLIENT_ID:-}"
      [[ -z "${TAILSCALE_OAUTH_CLIENT_ID}" ]] && TAILSCALE_OAUTH_CLIENT_ID="$(prompt_line 'Tailscale OAuth client ID: ' || true)"
      TAILSCALE_OAUTH_CLIENT_SECRET="${TAILSCALE_OAUTH_CLIENT_SECRET:-}"
      [[ -z "${TAILSCALE_OAUTH_CLIENT_SECRET}" ]] && TAILSCALE_OAUTH_CLIENT_SECRET="$(prompt_line 'Tailscale OAuth client secret: ' || true)"
      if [[ -z "${TAILSCALE_OAUTH_CLIENT_ID}" || -z "${TAILSCALE_OAUTH_CLIENT_SECRET}" ]]; then
        echo "ERROR: 'tailscale' edge type needs both a client ID and client secret. Set TAILSCALE_OAUTH_CLIENT_ID/TAILSCALE_OAUTH_CLIENT_SECRET in this shell, or re-run and answer the prompts." >&2
        exit 1
      fi
    fi

    # Not a secret — see TAILSCALE_CLUSTER_ISSUER_EMAIL's declaration up top.
    if [[ -z "${TAILSCALE_CLUSTER_ISSUER_EMAIL}" ]]; then
      TAILSCALE_CLUSTER_ISSUER_EMAIL="$(get_metadata "tailscale_cluster_issuer_email")"
    fi
    if [[ -z "${TAILSCALE_CLUSTER_ISSUER_EMAIL}" ]]; then
      cat >&2 <<'EOF'

Let's Encrypt requires a contact email for the ACME account
charts/straiker-edge's ClusterIssuer registers (renewal/expiry notices).
EOF
      TAILSCALE_CLUSTER_ISSUER_EMAIL="$(prompt_line "Cluster issuer contact email: " || true)"
      if [[ -z "${TAILSCALE_CLUSTER_ISSUER_EMAIL}" ]]; then
        echo "ERROR: 'tailscale' edge type needs a cluster issuer contact email. Set TAILSCALE_CLUSTER_ISSUER_EMAIL in this shell, or re-run and answer the prompt." >&2
        exit 1
      fi
    fi
    set_metadata "tailscale_cluster_issuer_email" "${TAILSCALE_CLUSTER_ISSUER_EMAIL}"
  fi

  # AI provider mode + credential(s) for Ascend's recon-agent — only asked
  # when 'ascend' is selected. The credential value is collected here (not
  # deferred to the later 'ai-provider-secrets' phase) so picking a mode has
  # an immediate next step; that phase just writes what got captured here
  # once the cluster/Secret exist. Checks the live Secret first to avoid
  # re-prompting once a key's already stored.
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
  2) bedrock   — use AWS Bedrock via EKS Pod Identity. The installer
                 creates a dedicated IAM role with bedrock:InvokeModel and
                 binds it to bifrost's ServiceAccount automatically — no
                 static keys or prompts needed. You'll need to request
                 access to these two models in the AWS Console:
                   - anthropic.claude-haiku-4-5-20251001-v1:0
                   - anthropic.claude-sonnet-4-6
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
        if [[ -z "$(get_metadata "bedrock_region")" ]]; then
          # Use the already-resolved AWS region — no need to ask.
          local bedrock_region="${AWS_REGION:-us-east-1}"
          cat >&2 <<EOF

Bedrock mode: the installer will create a dedicated IAM role with
bedrock:InvokeModel/InvokeModelWithResponseStream and bind it to bifrost's
ServiceAccount via EKS Pod Identity — no static keys needed.

You'll still need to request access to these two specific models under
Bedrock > Model access in the AWS Console (per-model, one-time,
console-only — no CLI equivalent). Ascend is pinned to exactly these two
model IDs and won't use any others, so there's no need to enable more:
  - anthropic.claude-haiku-4-5-20251001-v1:0
  - anthropic.claude-sonnet-4-6

Both are invoked through a Bedrock cross-region inference profile (required
for these models — the plain on-demand model ID is rejected). Next you'll
choose which profile:

EOF
          log "Using AWS region '${bedrock_region}' for Bedrock."
          set_metadata "bedrock_region" "${bedrock_region}"

          local default_profile
          default_profile="$(bedrock_profile_for_region "${bedrock_region}")"
          cat >&2 <<EOF
Cross-region inference profile:
  regional — pins every request to the '${default_profile}' profile family
             (derived from region '${bedrock_region}'), so requests never
             leave it (recommended for onprem — data residency tends to
             matter more than the cost savings global offers). Not every
             model has an endpoint in every regional profile family (e.g.
             neither Haiku 4.5 nor Sonnet 4.6 have one in apac) — confirm
             both pinned models are available in '${default_profile}'
             before picking this.
  global   — dynamically routes to whichever region has capacity, no pricing
             premium.

EOF
          local bedrock_profile_answer bedrock_inference_profile
          bedrock_profile_answer="$(prompt_line "Bedrock inference profile [global/regional] (default: regional): " || true)"
          case "${bedrock_profile_answer}" in
            regional|"") bedrock_inference_profile="${default_profile}" ;;
            global) bedrock_inference_profile="global" ;;
            *)
              echo "ERROR: Bedrock inference profile must be 'global' or 'regional', got '${bedrock_profile_answer}'." >&2
              exit 1
              ;;
          esac
          log "Using Bedrock inference profile '${bedrock_inference_profile}'."
          set_metadata "bedrock_inference_profile" "${bedrock_inference_profile}"
        else
          log "Bedrock region already set: $(get_metadata "bedrock_region")."
          log "Bedrock inference profile already set: $(get_metadata "bedrock_inference_profile")."
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
            bifrost_trial_response="$(curl -sf -H "Authorization: Bearer ${STRAIKER_CUSTOMER_KEY}" -H "X-Customer-Email: $(straiker_customer_email)" "${ARTIFACT_BROKER_BIFROST_TRIAL_URL}" || true)"
          fi
          if [[ -z "${bifrost_trial_response}" ]]; then
            echo "ERROR: Could not fetch your Bifrost trial virtual key from the artifact broker (${ARTIFACT_BROKER_BIFROST_TRIAL_URL}). Check network connectivity and that your Straiker contact has provisioned trial access for your account, then re-run." >&2
            exit 1
          fi
          AI_TRIAL_VIRTUAL_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual_key",""))' <<< "${bifrost_trial_response}" 2>/dev/null)"
          if [[ -z "${AI_TRIAL_VIRTUAL_KEY}" ]]; then
            echo "ERROR: Unexpected response from the artifact broker's Bifrost trial endpoint: ${bifrost_trial_response}" >&2
            exit 1
          fi
          # Use base_url from the broker response when present; fall back to the
          # hardcoded default so installs work even when the customer secret
          # doesn't include that field yet.
          AI_TRIAL_BIFROST_BASE_URL="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("base_url",""))' <<< "${bifrost_trial_response}" 2>/dev/null)"
          [[ -n "${AI_TRIAL_BIFROST_BASE_URL}" ]] || AI_TRIAL_BIFROST_BASE_URL="${DEFAULT_BIFROST_BASE_URL}"
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
    gateway-cert) phase_gateway_cert ;;
    aws-data) phase_aws_data ;;
    external-secrets) phase_external_secrets ;;
    artifacts-sync) phase_artifacts_sync ;;
    straiker-system) phase_straiker_system ;;
    shared-secrets) phase_shared_secrets ;;
    clickhouse) phase_clickhouse ;;
    data-bootstrap) phase_data_bootstrap ;;
    ch-sync) phase_ch_sync ;;
    platform-services) phase_platform_services ;;
    ingest) phase_ingest ;;
    verify-data-layer) phase_verify_data_layer ;;
    ai-provider-secrets) phase_ai_provider_secrets ;;
    straiker-core) phase_straiker_core ;;
    straiker-inference) phase_straiker_inference ;;
    straiker-defend) phase_straiker_defend ;;
    straiker-argus-v3) phase_straiker_argus_v3 ;;
    straiker-ascend) phase_straiker_ascend ;;
    tailscale-operator) phase_tailscale_operator ;;
    edge-infra) phase_edge_infra ;;
    cert-manager) phase_cert_manager ;;
    alb-controller) phase_alb_controller ;;
    external-dns) phase_external_dns ;;
    straiker-edge) phase_straiker_edge ;;
    observability) phase_observability ;;
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

# One-off action, not part of the normal phase pipeline: re-imports a
# certificate into the ARN already recorded as alb_certificate_arn — useful
# for rotating an imported certificate that doesn't auto-renew itself (the
# --alb-certificate-arn you provide for alb, or for xalb without
# --xalb-route53). Only works against an ARN that's itself an imported
# certificate — ACM rejects `import-certificate --certificate-arn`
# targeting an ACM-issued one, so this has no use (and isn't needed) for
# xalb --xalb-route53's auto-issued/DNS-validated certificate, which
# renews itself. Re-imports
# into the SAME ARN, so charts/straiker-edge's Ingress (which references
# the ARN, not the cert content) needs no changes, and no Helm
# upgrade/restart is needed — the ALB picks up the new content
# automatically.
update_alb_certificate() {
  require_command aws

  local arn
  arn="$(get_metadata "alb_certificate_arn")"
  if [[ -z "${arn}" ]]; then
    echo "ERROR: No ALB certificate ARN on record. Run the installer with --edge-type alb or xalb first." >&2
    exit 1
  fi
  if [[ -z "${ALB_CERT_FILE}" || -z "${ALB_KEY_FILE}" ]]; then
    echo "ERROR: --alb-cert-file and --alb-key-file are required." >&2
    exit 1
  fi
  if [[ ! -f "${ALB_CERT_FILE}" ]]; then
    echo "ERROR: Certificate file '${ALB_CERT_FILE}' not found." >&2
    exit 1
  fi
  if [[ ! -f "${ALB_KEY_FILE}" ]]; then
    echo "ERROR: Key file '${ALB_KEY_FILE}' not found." >&2
    exit 1
  fi
  if [[ -n "${ALB_CHAIN_FILE}" && ! -f "${ALB_CHAIN_FILE}" ]]; then
    echo "ERROR: Certificate chain file '${ALB_CHAIN_FILE}' not found." >&2
    exit 1
  fi

  local cmd=(
    aws acm import-certificate --certificate-arn "${arn}"
    --certificate "fileb://${ALB_CERT_FILE}"
    --private-key "fileb://${ALB_KEY_FILE}"
    --region "${AWS_REGION}"
  )
  if [[ -n "${ALB_CHAIN_FILE}" ]]; then
    cmd+=(--certificate-chain "fileb://${ALB_CHAIN_FILE}")
  fi
  "${cmd[@]}"

  log "Certificate updated in place (ARN ${arn}). The ALB picks it up automatically — no Helm upgrade or restart needed."
}

main() {
  trap 'on_error $LINENO' ERR
  trap on_interrupt HUP INT TERM
  trap on_exit_report EXIT

  parse_args "$@"
  # --data-layer provisions ClickHouse and Aurora, which registry and grid need (grid's migration creates the
  # tables ingest writes to), so they join the default set. An explicit PLATFORM_SERVICES always wins.
  if [[ "${DATA_LAYER}" == "true" && "${PLATFORM_SERVICES_EXPLICIT}" != true ]]; then
    PLATFORM_SERVICES="foundation registry databridge portico grid api-gateway"
  fi
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

  if [[ "${UPDATE_ALB_CERTIFICATE}" == true ]]; then
    update_alb_certificate
    exit 0
  fi

  check_state_matches_cluster
  validate_cluster_name
  resolve_defend_engine
  capture_install_config
  remember_inference_settings || exit 1 # after capture_install_config: it needs the selected products
  # The gateway's domain/certificate choice is validated now, not 25 minutes into the install (same function, run without touching state).
  if [[ "${DATA_LAYER}" == "true" ]]; then
    ( mark_phase_blocked() { echo "ERROR: $1" >&2; return 1; }; set_metadata() { :; }; remember_gateway_settings ) || exit 1
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
  show_access_info
  show_bootstrap_admin_reminder
}

main "$@"
