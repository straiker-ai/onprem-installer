#!/usr/bin/env bash
set -euo pipefail

REPO_NAME="straiker"
REPO_URL="https://raw.githubusercontent.com/straiker-ai/onprem-installer/gh-pages"
RELEASE_NAME="straiker-system"
NAMESPACE="straiker-system"
CHART_VERSION=""
VALUES_FILE=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --repo-name NAME      Helm repo name (default: straiker)
  --repo-url URL        Helm repo URL (default: https://straiker-ai.github.io/onprem-installer)
  --release-name NAME   Helm release name (default: straiker-system)
  --namespace NAME      Kubernetes namespace (default: straiker-system)
  --chart-version VER   Pin a chart version
  --values FILE        Additional values file
  --dry-run            Render manifests without installing
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-name)
      REPO_NAME="$2"
      shift 2
      ;;
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --release-name)
      RELEASE_NAME="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --chart-version)
      CHART_VERSION="$2"
      shift 2
      ;;
    --values)
      VALUES_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

command -v helm >/dev/null 2>&1 || {
  echo "helm is required" >&2
  exit 1
}

helm repo add --force-update "$REPO_NAME" "$REPO_URL" >/dev/null
helm repo update >/dev/null

args=(
  upgrade
  --install
  "$RELEASE_NAME"
  "$REPO_NAME/straiker-system"
  --namespace
  "$NAMESPACE"
  --create-namespace
)

if [[ -n "$CHART_VERSION" ]]; then
  args+=(--version "$CHART_VERSION")
fi

if [[ -n "$VALUES_FILE" ]]; then
  args+=(-f "$VALUES_FILE")
fi

if [[ "$DRY_RUN" == true ]]; then
  args+=(--dry-run)
fi

helm "${args[@]}"
