#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# What actually ships to customers inside the bundle: the phased installer +
# launcher (run on the customer's machine) and the Terraform modules. Release-only
# tooling (this script, render-launcher.sh) is deliberately left out.
BUNDLE_PATHS=(
  scripts/install-straiker.sh
  scripts/uninstall-straiker.sh
  scripts/launch-straiker.sh
  scripts/nuke-eks.sh
  terraform
)

OUTPUT_DIR="${REPO_ROOT}/dist/installer"
VERSION=""

usage() {
  cat <<'EOF'
Usage:
  package-installer-bundle.sh [options]

Options:
  --version <version>   Bundle version label. Defaults to git short SHA or "workspace".
  --output-dir <dir>    Output directory (default: dist/installer).
  -h, --help            Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        VERSION=${2:-}
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR=${2:-}
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

resolve_version() {
  if [[ -n "${VERSION}" ]]; then
    return
  fi

  if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VERSION="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  else
    VERSION="workspace"
  fi
}

main() {
  parse_args "$@"
  resolve_version

  mkdir -p "${OUTPUT_DIR}"
  local archive_path="${OUTPUT_DIR}/straiker-installer-${VERSION}.tar.gz"

  tar -czf "${archive_path}" \
    -C "${REPO_ROOT}" \
    "${BUNDLE_PATHS[@]}"

  echo "${archive_path}"
}

main "$@"
