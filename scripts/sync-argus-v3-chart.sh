#!/usr/bin/env bash
# Vendors the Argus v3 chart (straiker-ai/argus, deploy/helm/argus-v3) into charts/straiker-argus-v3 at a pinned
# commit; same idea as sync-api-gateway-chart.sh.
#
#   scripts/sync-argus-v3-chart.sh <full-commit-sha> [--repo PATH]
#
# Drops the SaaS per-environment overlays (values-prod-*, values-stage): they carry internal account IDs and ARNs that
# must never ship. charts/straiker-argus-v3/values-onprem.yaml is ours (hand-maintained, never overwritten).
# The engine image tag is v3-<sha>; the image-mirror entry in charts/straiker-artifact is kept in step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGUS_REPO="${ARGUS_REPO:-${HOME}/Desktop/Git_Repo/argus}"
sha=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) ARGUS_REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) sha="$1"; shift ;;
  esac
done
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: $0 <40-character commit sha> [--repo PATH]" >&2; exit 1; }
git -C "${ARGUS_REPO}" cat-file -e "${sha}^{commit}" 2>/dev/null \
  || { echo "commit ${sha} not found in ${ARGUS_REPO} (git fetch first)" >&2; exit 1; }

src="deploy/helm/argus-v3"
dest="${REPO_ROOT}/charts/straiker-argus-v3"
tmp="$(mktemp -d)"
git -C "${ARGUS_REPO}" archive "${sha}" "${src}" | tar -x -C "${tmp}"
mkdir -p "${dest}"
find "${dest}" -mindepth 1 -maxdepth 1 ! -name values-onprem.yaml -exec rm -rf {} +
cp -R "${tmp}/${src}/." "${dest}/"
rm -f "${dest}"/values-prod-*.yaml "${dest}"/values-stage.yaml "${dest}/README.md"
rm -rf "${tmp}"

python3 - "${dest}" "${sha}" <<'PY'
import re, sys
dest, sha = sys.argv[1:]
p = dest + "/Chart.yaml"
s = open(p).read()
s = re.sub(r"(?m)^name:.*$", "name: straiker-argus-v3", s, count=1)
s = re.sub(r"(?m)^appVersion:.*$", f'appVersion: "v3-{sha}"', s, count=1)
open(p, "w").write(s)
PY
# Upstream defaults point at Straiker's own dev environment. Neutralize every internal identifier: the image repository
# and model endpoints are always set by the installer (an unset model endpoint means "controls unavailable").
python3 - "${dest}" "${sha}" <<'PY'
import re, sys
dest, sha = sys.argv[1:]
p = dest + "/values.yaml"
s = open(p).read()
# The engine image as customers receive it: repository straiker/argus (artifact chart mirror entry), tag v3-<sha>.
s = re.sub(r"\d{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/be/argus", "straiker/argus", s)
s = re.sub(r"(?m)^(\s+tag:\s*)v3-latest\b", lambda m: m.group(1) + "v3-" + sha, s)
s = re.sub(r"arn:aws[a-z-]*:iam::\d{12}:role/[^\"'\s]*", "arn:aws:iam::<account-id>:role/<role>", s)
s = re.sub(r"rediss?://[^\"'\s]+", "rediss://<redis-endpoint>:6379", s)
s = re.sub(r"[a-z0-9.-]*\.kafka-serverless\.[a-z0-9-]+\.amazonaws\.com:\d+", "<msk-bootstrap>:9098", s)
s = re.sub(r'"https://[^"]*(?:straiker\.ai|run\.app)[^"]*"', '""', s)
s = re.sub(r'bucket: "s6r-[^"]*"', 'bucket: ""', s)
open(p, "w").write(s)
PY
leaks="$(grep -rnE '[0-9]{12}|straiker\.ai|run\.app|s6r-|cache\.amazonaws|kafka-serverless|rds\.amazonaws|\.es\.amazonaws|elb\.amazonaws' "${dest}" --include='*.yaml' --include='*.tpl' --exclude=values-onprem.yaml || true)"
if [[ -n "${leaks}" ]]; then
  echo "internal identifiers still present in the vendored chart; refusing:" >&2
  echo "${leaks}" >&2
  exit 1
fi
echo "synced argus-v3 @ ${sha} -> charts/straiker-argus-v3 (image tag v3-${sha})"
