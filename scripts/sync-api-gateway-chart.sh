#!/usr/bin/env bash
# Vendors the api-gateway chart (straiker-ai/api-gateway, deploy/helm/api-gateway) into
# charts/platform-api-gateway at a pinned release tag; same idea as sync-platform-charts.sh.
#
#   scripts/sync-api-gateway-chart.sh v2.3.12 [--repo PATH]
#
# Keeps only values/routes.yaml (the chart reads it via .Files.Get); drops every other values
# file — notably the upstream values-onprem.yaml, which embeds a sample RSA private key and a
# placeholder client secret that must never ship. charts/platform-api-gateway/values-onprem.yaml
# is ours (hand-maintained, never overwritten); credentials are generated per install.
# Routes to services in the 'platform' namespace are rewritten to the release namespace, and the
# image-mirror tag in charts/straiker-artifact is kept in step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GW_REPO="${API_GATEWAY_REPO:-${HOME}/Desktop/Git_Repo/api-gateway}"
tag=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) GW_REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    v*) tag="$1"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "${tag}" ]] || { echo "usage: $0 vX.Y.Z [--repo PATH]" >&2; exit 1; }
git -C "${GW_REPO}" rev-parse --verify --quiet "refs/tags/${tag}^{commit}" >/dev/null \
  || { echo "tag ${tag} not found in ${GW_REPO}" >&2; exit 1; }

src="deploy/helm/api-gateway"
dest="${REPO_ROOT}/charts/platform-api-gateway"
tmp="$(mktemp -d)"
git -C "${GW_REPO}" archive "${tag}" "${src}" | tar -x -C "${tmp}"
mkdir -p "${dest}"
find "${dest}" -mindepth 1 -maxdepth 1 ! -name values-onprem.yaml -exec rm -rf {} +
cp -R "${tmp}/${src}/." "${dest}/"
find "${dest}/values" -type f ! -name routes.yaml -delete

python3 - "${dest}" "${tag}" <<'PY'
import re, sys
dest, tag = sys.argv[1:]
p = dest + "/Chart.yaml"
s = open(p).read()
s = re.sub(r"(?m)^name:.*$", "name: platform-api-gateway", s, count=1)
s = re.sub(r"(?m)^version:.*$", f'version: "{tag.lstrip("v")}"', s, count=1)
s = re.sub(r"(?m)^appVersion:.*\n", "", s)
s = re.sub(r"(?m)^(version:.*)$", rf'\1\nappVersion: "{tag}"', s, count=1)
open(p, "w").write(s)
# routes: http://<svc>.platform[:port] -> release namespace (the file is rendered with tpl)
p = dest + "/values/routes.yaml"
s = open(p).read()
s = re.sub(r"(http://[a-z0-9-]+)\.platform(?=[:/\s\"']|$)", r"\1.{{ .Release.Namespace }}", s)
open(p, "w").write(s)
PY
rm -rf "${tmp}"

REPO="straiker/api-gateway" NEWTAG="${tag}" perl -0777 -pi -e \
  's/(source:[ \t]*\S*\/\Q$ENV{REPO}\E[ \t]*\n[ \t]*tag:[ \t]*)\S+/${1}$ENV{NEWTAG}/' \
  "${REPO_ROOT}/charts/straiker-artifact/values.yaml"
echo "synced api-gateway @ ${tag} -> charts/platform-api-gateway"
