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
# Named EDGE_INFRA_* (not EDGE_*) to avoid colliding with the unrelated
# charts/straiker-edge Helm-chart identifiers (EDGE_RELEASE/EDGE_TYPE/
# EDGE_CHART_NAME) already used throughout this script.
EDGE_INFRA_SRC="${REPO_ROOT}/terraform/aws/edge"

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
EDGE_INFRA_DIR="${TF_WORK_ROOT}/aws/edge"
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

# Argus detection engine (charts/straiker-defend) — backs Straiker's "Defend"
# product, but always installed regardless of PRODUCTS_OPT: charts/straiker-
# ascend's own probe-worker/recon-worker call Argus's /api/v1/detect directly
# for several detection categories (amt_attack_* and others), so an Ascend-
# only install still needs it running. Runs after straiker-inference and
# straiker-system.
DEFEND_RELEASE="straiker-defend"
DEFEND_CHART_NAME="straiker-defend"
DEFEND_SERVICE_ACCOUNT="straiker-defend"

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
# One-off hardening action, not part of the normal phase pipeline — see
# disable_builtin_admin()'s own comment.
DISABLE_BUILTIN_ADMIN=false
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
declare -a ALL_PHASES=("eks-tfbe" "eks-cluster" "karpenter" "k8s-preflight" "aws-artifacts" "artifacts-sync" "straiker-system" "shared-secrets" "ai-provider-secrets" "straiker-core" "straiker-inference" "straiker-defend" "straiker-ascend" "tailscale-operator" "edge-infra" "cert-manager" "alb-controller" "external-dns" "straiker-edge")
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
  --disable-builtin-admin         One-off hardening action, not part of the normal install:
                                   removes straiker-core's bootstrap admin login
                                   (admin@<appDomain>, same password hash on every onprem
                                   install) from dex's config and exits. Run this any time
                                   after onboarding a real admin (a local account created
                                   through the UI, or your own configured OIDC IdP) — do NOT
                                   run it before you've confirmed you can log in as someone
                                   else, since dex's dynamic local logins and any configured
                                   OIDC IdP are unaffected either way, only this one static
                                   entry is removed. Prompts for confirmation unless --yes.
                                   Reversible via a normal install with --values setting
                                   straiker-frontend.dex.staticAdminEnabled: true.
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
  --edge-type <internal|none|tailscale|alb>
                                   How straiker-edge exposes app/defend/ascend externally
                                   (default: none). internal = Caddy reverse proxy with
                                   self-signed certs. none = install nothing; bring your own
                                   ingress/LoadBalancer (current default). tailscale = same
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
                             for argus calling straiker-inference. All three charts read
                             this same Secret name; this phase is what creates it.
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
                             settings-sync daemon — charts/straiker-defend). Always runs,
                             regardless of product selection — straiker-ascend's iris calls
                             Argus's /api/v1/detect directly for several detection
                             categories, so Ascend-only installs need this too. Runs after
                             straiker-inference (needs its per-model Services) and
                             straiker-system (needs its Redis/OpenSearch/Benthos and shared
                             NodePool).
 13) straiker-ascend      - install/upgrade release 'straiker-ascend' (iris automated
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
        line_cost="$(awk -v n="${nat_count}" -v h="${hours_per_month}" 'BEGIN { printf "%.2f", n * 0.045 * h }')"
        echo " NAT gateway (${nat_count}x, base charge only, excludes data processing): \$${line_cost}/mo"
        total="$(awk -v t="${total}" -v l="${line_cost}" 'BEGIN { printf "%.2f", t + l }')"
      fi
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
      --disable-builtin-admin)
        DISABLE_BUILTIN_ADMIN=true
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

  local values_file
  for values_file in "${VALUES_FILES[@]+"${VALUES_FILES[@]}"}"; do
    cmd+=(-f "${values_file}")
  done
  "${cmd[@]}"
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
  log "Secret '${SHARED_SECRETS_NAME}' has all expected service-to-service credentials."
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

  # straiker-frontend is a subchart of straiker-core — overriding its values
  # from the parent release needs the "<subchart-name>." prefix (unlike
  # global.* above); a bare "frontend.internalApiKey...=" would silently
  # create an unused top-level key instead.
  cmd+=(--set "straiker-frontend.frontend.internalApiKey.secretName=${SHARED_SECRETS_NAME}")
  cmd+=(--set "straiker-frontend.frontend.internalApiKey.secretKey=INTERNAL_API_KEY")

  # Unconditional — straiker-defend is always installed now (see
  # phase_straiker_defend), regardless of product selection.
  cmd+=(--set "straiker-frontend.frontend.argusEndpoint=http://${DEFEND_RELEASE}.${INFRA_NAMESPACE}.svc.cluster.local")

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

# Argus — always installed, regardless of product selection: charts/
# straiker-ascend's own iris calls Argus's /api/v1/detect directly for
# several detection categories, so an Ascend-only install still needs this
# running (not just customers who selected Defend as a product). Depends on
# straiker-system (Redis/OpenSearch/Benthos, shared NodePool) and straiker-
# inference's per-model releases (SYS__LLM_ENDPOINTS__* targets) already
# being up; checks straiker-system's live release status the same way
# phase_straiker_core does, since a phase that merely ran earlier isn't proof
# it's still healthy.
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

# Helm 4 defaults to server-side apply, where --force-conflicts is needed to
# resolve a field-manager conflict from an out-of-band edit (e.g. `kubectl
# set env`) instead of failing the upgrade outright. Helm 3's default
# client-side apply doesn't hit that conflict in the first place and, on at
# least some 3.x versions, doesn't have the flag at all -- passing an
# unrecognized flag is a hard "unknown flag" error, not a harmless no-op, so
# this must be feature-detected rather than assumed (confirmed live: AWS
# CloudShell's preinstalled helm is older than a locally-installed Helm 4 and
# rejected this flag outright).
helm_supports_force_conflicts() {
  helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts'
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

  local cmd=(
    helm upgrade --install "${ASCEND_RELEASE}" "${HELM_REPO_NAME}/${ASCEND_CHART_NAME}"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --set "global.dockerRegistry=$(docker_registry_with_prefix "${ecr_registry}")"
    --set "db.host=postgres.${INFRA_NAMESPACE}.svc.cluster.local"
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  # See helm_supports_force_conflicts's declaration above for why this can't
  # just always be passed. (Note: `kubectl patch --type=json remove
  # metadata/managedFields` does NOT work as an alternative fix on Helm 4 --
  # the API server recomputes managedFields from the request and ignores a
  # direct edit to that field.)
  helm_supports_force_conflicts && cmd+=(--force-conflicts)
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

  "${cmd[@]}"
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
      enable_route53="$(get_metadata "alb_route53_automation")"
      enable_external_dns=false
      enable_cert_manager=false
      domain="$(get_metadata "custom_domain")"
      ;;
    xalb)
      enable_alb_controller=true
      enable_route53="$(get_metadata "xalb_route53_automation")"
      enable_external_dns="$(get_metadata "xalb_route53_automation")"
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

  tofu -chdir="${EDGE_INFRA_DIR}" init -upgrade -input=false -migrate-state -force-copy
  tofu -chdir="${EDGE_INFRA_DIR}" apply -auto-approve -input=false \
    -var="region=${AWS_REGION}" \
    -var="prefix=${TF_PREFIX}" \
    -var="cluster_name=${CLUSTER_NAME}" \
    -var="san_hostnames=${san_hostnames_json}" \
    -var="enable_bastion=$(get_metadata "alb_provision_bastion")" \
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
    -var="cert_manager_service_account_name=${CERT_MANAGER_SERVICE_ACCOUNT}"

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

  local ecr_registry
  ecr_registry="$(get_metadata "ecr_registry")"
  local cmd=(
    helm upgrade --install "${EDGE_RELEASE}" "${HELM_REPO_NAME}/${EDGE_CHART_NAME}"
    --namespace "${INFRA_NAMESPACE}"
    --create-namespace
    --wait
    --timeout "${HELM_TIMEOUT}"
    --set "edgeType=${EDGE_TYPE}"
  )
  if [[ "${EDGE_TYPE}" == "tailscale" ]]; then
    cmd+=(--set "tailscale.domain=$(get_metadata "custom_domain")")
    cmd+=(--set "tailscale.clusterIssuerEmail=${TAILSCALE_CLUSTER_ISSUER_EMAIL:-$(get_metadata "tailscale_cluster_issuer_email")}")
    cmd+=(--set "tailscale.hostedZoneId=$(get_metadata "tailscale_hosted_zone_id")")
    cmd+=(--set "tailscale.region=${AWS_REGION}")
  fi
  if [[ "${EDGE_TYPE}" == "alb" ]]; then
    cmd+=(--set "alb.domain=$(get_metadata "custom_domain")")
    cmd+=(--set "alb.certificateArn=$(get_metadata "alb_certificate_arn")")
    cmd+=(--set "alb.inboundCidrs=$(get_metadata "internal_lb_source_ranges")")
    local alb_subnets
    alb_subnets="$(get_metadata "alb_subnets")"
    if [[ -n "${alb_subnets}" ]]; then
      cmd+=(--set "alb.subnets=${alb_subnets}")
    fi
  fi
  if [[ "${EDGE_TYPE}" == "xalb" ]]; then
    cmd+=(--set "xalb.domain=$(get_metadata "custom_domain")")
    cmd+=(--set "xalb.certificateArn=$(get_metadata "alb_certificate_arn")")
    local xalb_cidrs
    xalb_cidrs="$(get_metadata "internal_lb_source_ranges")"
    if [[ -n "${xalb_cidrs}" ]]; then
      cmd+=(--set "xalb.inboundCidrs=${xalb_cidrs}")
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
  "${cmd[@]}"
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
    log ""
    if [[ "$(get_metadata "xalb_route53_automation")" == "true" ]]; then
      log "Certificate is real and DNS-validated — no browser trust warning."
      log "DNS is managed automatically by ExternalDNS — the above hostnames should"
      log "resolve on their own once the controller has synced (usually under a minute)."
    else
      log "Using the certificate from --alb-certificate-arn. Point ${custom_domain}'s"
      log "DNS at the ALB yourself (Route53 ALIAS record, or however you manage that"
      log "zone). Find its DNS name with:"
      log "  kubectl get ingress -n ${INFRA_NAMESPACE} ${EDGE_RELEASE}-xalb"
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
                          Services directly (default).
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
  5) xalb               — same as alb, but internet-facing and sharing an
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
    local edge_type_answer
    edge_type_answer="$(prompt_line 'Edge type [internal/none/tailscale/alb/xalb] (default: none): ' || true)"
    case "${edge_type_answer}" in
      1|internal) EDGE_TYPE=internal ;;
      2|none|"") EDGE_TYPE=none ;;
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
    artifacts-sync) phase_artifacts_sync ;;
    straiker-system) phase_straiker_system ;;
    shared-secrets) phase_shared_secrets ;;
    ai-provider-secrets) phase_ai_provider_secrets ;;
    straiker-core) phase_straiker_core ;;
    straiker-inference) phase_straiker_inference ;;
    straiker-defend) phase_straiker_defend ;;
    straiker-ascend) phase_straiker_ascend ;;
    tailscale-operator) phase_tailscale_operator ;;
    edge-infra) phase_edge_infra ;;
    cert-manager) phase_cert_manager ;;
    alb-controller) phase_alb_controller ;;
    external-dns) phase_external_dns ;;
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

# One-off hardening action (--disable-builtin-admin), not part of the normal
# phase pipeline — run any time after a customer has onboarded a real admin
# (a local login created through the UI, or their own OIDC IdP) to remove
# straiker-core's bootstrap admin, whose password hash is identical across
# every onprem install. Only removes that one static entry — dex's own
# dynamically-managed local logins and any configured external IdP are
# untouched either way. Reversible via a normal install with --values
# setting straiker-frontend.dex.staticAdminEnabled: true.
disable_builtin_admin() {
  require_command helm
  require_command kubectl

  local namespace="${INFRA_NAMESPACE:-}"
  [[ -z "${namespace}" ]] && namespace="$(get_metadata "namespace")"
  namespace="${namespace:-straiker}"

  ensure_k8s_ready_for_charts || exit 1

  local core_status
  core_status="$(helm status "${APP_RELEASE}" -n "${namespace}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || true)"
  if [[ "${core_status}" != "deployed" ]]; then
    echo "ERROR: Release '${APP_RELEASE}' in namespace '${namespace}' is not healthy (status: '${core_status:-not installed}'). Nothing to disable." >&2
    exit 1
  fi

  if [[ "${AUTO_YES}" != true ]]; then
    cat >&2 <<'EOF'

This will disable the default bootstrap admin login (admin@<appDomain>) by
removing it from dex's config entirely — every onprem install ships with the
SAME password hash for this account, so leaving it enabled indefinitely is a
real risk. Before continuing, make sure you can already log in as a
different admin: either a local account created through the UI, or your own
configured OIDC IdP. This is reversible (re-run with --values setting
straiker-frontend.dex.staticAdminEnabled: true), but you'd need working
admin access to even do that.

Type 'disable' and press Enter to continue.
EOF
    local typed
    if ! typed="$(prompt_line '> ')"; then
      echo "ERROR: No interactive terminal available to confirm. Re-run with --yes if you're sure." >&2
      exit 1
    fi
    if [[ "${typed}" != "disable" ]]; then
      echo "ERROR: Not confirmed; aborting. No changes made." >&2
      exit 1
    fi
  fi

  helm repo add --force-update "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  local cmd=(
    helm upgrade --install "${APP_RELEASE}" "${HELM_REPO_NAME}/${APP_CHART_NAME}"
    --namespace "${namespace}"
    --reuse-values
    --set "straiker-frontend.dex.staticAdminEnabled=false"
    --wait
    --timeout "${HELM_TIMEOUT}"
  )
  if [[ -n "${CHART_VERSION}" ]]; then
    cmd+=(--version "${CHART_VERSION}")
  fi
  "${cmd[@]}"

  log "Bootstrap admin login disabled — dex restarted automatically to pick up the change (config checksum changed). Confirm you can still log in as your real admin before closing this session."
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

  if [[ "${DISABLE_BUILTIN_ADMIN}" == true ]]; then
    disable_builtin_admin
    exit 0
  fi

  if [[ "${UPDATE_ALB_CERTIFICATE}" == true ]]; then
    update_alb_certificate
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
