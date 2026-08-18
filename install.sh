#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATE_DIR="${HOME}/.straiker"
CACHE_ROOT_DEFAULT="${STATE_DIR}/installer"
DEFAULT_INSTALLER_VERSION="${STRAIKER_DEFAULT_INSTALLER_VERSION:-ddf60e6}"
DEFAULT_INSTALLER_BUNDLE_URL="${STRAIKER_DEFAULT_INSTALLER_BUNDLE_URL:-https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist/bundles/straiker-installer-ddf60e6.tar.gz}"

INSTALLER_VERSION="${STRAIKER_INSTALLER_VERSION:-}"
INSTALLER_BUNDLE_URL="${STRAIKER_INSTALLER_BUNDLE_URL:-}"
INSTALLER_CACHE_DIR="${STRAIKER_INSTALLER_CACHE_DIR:-${CACHE_ROOT_DEFAULT}}"
FORCE_REFRESH=false

declare -a INSTALLER_ARGS=()

if [[ "${DEFAULT_INSTALLER_VERSION}" == __STRAIKER_*__ ]]; then
  DEFAULT_INSTALLER_VERSION="workspace"
fi

if [[ "${DEFAULT_INSTALLER_BUNDLE_URL}" == __STRAIKER_*__ ]]; then
  DEFAULT_INSTALLER_BUNDLE_URL=""
fi

usage() {
  cat <<'EOF'
Usage:
  launch-straiker.sh [launcher-options] [-- installer-options]

Launcher options:
  --installer-version <version>   Bundle version to cache and execute.
  --installer-bundle-url <url>    Tarball URL for the installer bundle.
  --installer-cache-dir <dir>     Cache root (default: ~/.straiker/installer).
  --upgrade-installer             Re-download the selected bundle version.
  -h, --help                      Show this help.

All other arguments are passed through to scripts/install-straiker.sh.
EOF
}

log() {
  echo "[launcher] $*" >&2
}

require_command() {
  local cmd=$1
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' is not installed or not on PATH." >&2
    exit 1
  fi
}

sanitize_version() {
  local value=$1
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value// /_}"
  echo "${value}"
}

resolve_local_bundle_source() {
  local candidate_root=$1
  if [[ -f "${candidate_root}/scripts/install-straiker.sh" && -d "${candidate_root}/terraform" ]]; then
    echo "${candidate_root}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --installer-version)
        INSTALLER_VERSION=${2:-}
        shift 2
        ;;
      --installer-bundle-url)
        INSTALLER_BUNDLE_URL=${2:-}
        shift 2
        ;;
      --installer-cache-dir)
        INSTALLER_CACHE_DIR=${2:-}
        shift 2
        ;;
      --upgrade-installer)
        FORCE_REFRESH=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          INSTALLER_ARGS+=("$1")
          shift
        done
        return
        ;;
      *)
        INSTALLER_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

determine_installer_version() {
  # Unlike launch-uninstall.sh, this deliberately does NOT fall back to
  # ~/.straiker/install.json's recorded version: re-running install.sh should
  # pick up whatever was just fetched (the latest published fix), not silently
  # keep re-using whatever version a much earlier attempt happened to record.
  if [[ -n "${INSTALLER_VERSION}" ]]; then
    return
  fi
  INSTALLER_VERSION="${DEFAULT_INSTALLER_VERSION}"
}

determine_installer_url() {
  if [[ -n "${INSTALLER_BUNDLE_URL}" ]]; then
    return
  fi
  INSTALLER_BUNDLE_URL="${DEFAULT_INSTALLER_BUNDLE_URL}"
}

copy_local_bundle() {
  local source_root=$1
  local bundle_root=$2
  rm -rf "${bundle_root}/scripts" "${bundle_root}/terraform"
  mkdir -p "${bundle_root}/scripts"
  cp "${source_root}/scripts/install-straiker.sh" "${bundle_root}/scripts/"
  cp "${source_root}/scripts/uninstall-straiker.sh" "${bundle_root}/scripts/"
  cp "${source_root}/scripts/launch-straiker.sh" "${bundle_root}/scripts/"
  cp "${source_root}/scripts/nuke-eks.sh" "${bundle_root}/scripts/"
  cp -R "${source_root}/terraform" "${bundle_root}/terraform"
}

download_bundle() {
  local bundle_url=$1
  local bundle_root=$2
  local tmp_dir archive_path

  require_command curl
  require_command tar

  tmp_dir="$(mktemp -d)"
  archive_path="${tmp_dir}/installer-bundle.tar.gz"

  curl -fsSL "${bundle_url}" -o "${archive_path}"
  rm -rf "${bundle_root}"
  mkdir -p "${bundle_root}"
  tar -xzf "${archive_path}" -C "${bundle_root}"
  rm -rf "${tmp_dir}"

  if [[ ! -f "${bundle_root}/scripts/install-straiker.sh" || ! -d "${bundle_root}/terraform" ]]; then
    echo "ERROR: installer bundle from '${bundle_url}' is missing scripts/install-straiker.sh or terraform." >&2
    exit 1
  fi
}

ensure_bundle() {
  local version_dir source_root

  mkdir -p "${INSTALLER_CACHE_DIR}"
  version_dir="${INSTALLER_CACHE_DIR}/$(sanitize_version "${INSTALLER_VERSION}")"

  if [[ "${FORCE_REFRESH}" != true && -f "${version_dir}/scripts/install-straiker.sh" && -d "${version_dir}/terraform" ]]; then
    echo "${version_dir}"
    return
  fi

  source_root="$(resolve_local_bundle_source "${REPO_ROOT}")"
  if [[ -n "${source_root}" && -z "${INSTALLER_BUNDLE_URL}" ]]; then
    log "Refreshing cached installer bundle from local workspace."
    copy_local_bundle "${source_root}" "${version_dir}"
    echo "${version_dir}"
    return
  fi

  if [[ -z "${INSTALLER_BUNDLE_URL}" ]]; then
    echo "ERROR: no installer bundle URL is configured for version '${INSTALLER_VERSION}'." >&2
    echo "       Set STRAIKER_INSTALLER_BUNDLE_URL or pass --installer-bundle-url." >&2
    exit 1
  fi

  log "Downloading installer bundle ${INSTALLER_VERSION}."
  download_bundle "${INSTALLER_BUNDLE_URL}" "${version_dir}"
  echo "${version_dir}"
}

main() {
  parse_args "$@"

  require_command bash

  determine_installer_version
  determine_installer_url

  local bundle_root installer_path
  bundle_root="$(ensure_bundle)"
  installer_path="${bundle_root}/scripts/install-straiker.sh"

  if [[ ! -x "${installer_path}" ]]; then
    chmod +x "${installer_path}"
  fi

  exec env \
    STRAIKER_INSTALLER_BUNDLE_VERSION="${INSTALLER_VERSION}" \
    STRAIKER_INSTALLER_BUNDLE_HOME="${bundle_root}" \
    STRAIKER_INSTALLER_BUNDLE_URL="${INSTALLER_BUNDLE_URL}" \
    bash "${installer_path}" "${INSTALLER_ARGS[@]+"${INSTALLER_ARGS[@]}"}"
}

main "$@"
