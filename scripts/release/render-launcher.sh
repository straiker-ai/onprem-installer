#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/../launch-straiker.sh"
OUTPUT_PATH=""
VERSION=""
BUNDLE_URL=""

usage() {
  cat <<'EOF'
Usage:
  render-launcher.sh --version <version> --bundle-url <url> --output <path> [--template <path>]

Defaults --template to launch-straiker.sh; pass launch-uninstall.sh to render the uninstaller.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        VERSION=${2:-}
        shift 2
        ;;
      --bundle-url)
        BUNDLE_URL=${2:-}
        shift 2
        ;;
      --template)
        TEMPLATE_PATH=${2:-}
        shift 2
        ;;
      --output)
        OUTPUT_PATH=${2:-}
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

main() {
  parse_args "$@"

  if [[ -z "${VERSION}" || -z "${BUNDLE_URL}" || -z "${OUTPUT_PATH}" ]]; then
    echo "ERROR: --version, --bundle-url, and --output are required." >&2
    usage >&2
    exit 1
  fi

  python3 - "${TEMPLATE_PATH}" "${OUTPUT_PATH}" "${VERSION}" "${BUNDLE_URL}" <<'PY'
import pathlib, sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
version = sys.argv[3]
bundle_url = sys.argv[4]

content = template_path.read_text(encoding="utf-8")
content = content.replace("__STRAIKER_INSTALLER_DEFAULT_VERSION__", version)
content = content.replace("__STRAIKER_INSTALLER_DEFAULT_BUNDLE_URL__", bundle_url)
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(content, encoding="utf-8")
PY

  chmod +x "${OUTPUT_PATH}"
}

main "$@"
