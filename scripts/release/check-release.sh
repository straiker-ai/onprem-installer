#!/usr/bin/env bash
# Checks that a version published to Distr is complete and matches this git checkout. Read-only.
#
#   scripts/release/check-release.sh --version onprem-2026.12.0-rc4
#
# Run it on the publisher, logged in to Distr (crane/oras), from a clean checkout of the commit you released.
# Checks: (1) every artifact tag exists, (2) release.json is complete (digests, counts) and matches the tags,
# (3) every image layer is in the registry, (4) the release was built from this checkout's commit,
# (5) the installer tarball equals `git archive HEAD` (scripts, terraform, charts).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY="registry.straiker.ai/straiker/onprem"
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    -h | --help) sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option '$1'" >&2; exit 2 ;;
  esac
done
[[ -n "${VERSION}" ]] || { echo "ERROR: --version is required." >&2; exit 2; }
for c in crane oras jq tar git diff; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' is required." >&2; exit 2; }; done

fail=0
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
warn() { printf '  WARN  %s\n' "$*"; }

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

echo "== 1. Artifact tags for ${VERSION}"
for r in images charts installer release; do
  if crane digest "${REGISTRY}/${r}:${VERSION}" >/dev/null 2>&1; then ok "${r}:${VERSION}"; else bad "${r}:${VERSION} is not published"; fi
done
if ! oras pull "${REGISTRY}/release:${VERSION}" -o "${W}/rel" >/dev/null 2>&1 || [[ ! -s "${W}/rel/release.json" ]]; then
  bad "cannot download release.json: the rest cannot be checked"
  echo; echo "RESULT: ${fail} problem(s)"; exit 1
fi
RJ="${W}/rel/release.json"
while IFS= read -r ref; do
  if crane digest "${ref}" >/dev/null 2>&1; then ok "model ${ref##*/models/}"; else bad "model ${ref} is not published"; fi
done < <(jq -r '.models[].dest' "${RJ}")

echo "== 2. release.json is complete and matches the tags"
echo "  images $(jq '.images|length' "${RJ}"), charts $(jq '.charts|length' "${RJ}") + $(jq '.thirdPartyCharts|length' "${RJ}") third-party, models $(jq '.models|length' "${RJ}")"
[[ "$(jq '[.images[]|select(.layerDigest==null or .digest==null)]|length' "${RJ}")" == 0 ]] && ok "every image has a digest and a layer" || bad "some images have no digest or layer"
[[ "$(jq '[.models[]|select(.digest==null or .digest=="")]|length' "${RJ}")" == 0 ]] && ok "every model has a digest" || bad "some models have no digest"
for pair in "imagesArtifact:images" "chartsArtifact:charts"; do
  key="${pair%%:*}"; repo="${pair##*:}"
  have="$(jq -r ".${key}.digest // empty" "${RJ}")"; now="$(crane digest "${REGISTRY}/${repo}:${VERSION}" 2>/dev/null)"
  [[ -n "${have}" && "${have}" == "${now}" ]] && ok "${repo} digest matches the registry" || bad "${repo} digest in release.json (${have:-empty}) differs from the registry (${now:-none})"
done
have="$(jq -r '.installer.digest // empty' "${RJ}")"; now="$(crane digest "${REGISTRY}/installer:${VERSION}" 2>/dev/null)"
[[ -n "${have}" && "${have}" == "${now}" ]] && ok "installer digest matches the registry" || bad "installer digest in release.json (${have:-empty}) differs from the registry (${now:-none})"

echo "== 3. Every image layer is in the registry"
imgs_repo="$(jq -r '.imagesArtifact.dest' "${RJ}")"; imgs_repo="${imgs_repo%:*}"
missing=0
while IFS= read -r d; do
  oras blob fetch --descriptor "${imgs_repo}@${d}" >/dev/null 2>&1 || { bad "image layer ${d} is missing"; missing=$((missing + 1)); }
done < <(jq -r '.images[] | (.layers // [.layerDigest])[]' "${RJ}")
[[ "${missing}" == 0 ]] && ok "all image layers present"

echo "== 4. Built from this checkout"
rel_commit="$(jq -r '.gitCommit // "unknown"' "${RJ}")"; here="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
if [[ "${rel_commit}" == "${here}" ]]; then ok "release commit ${rel_commit:0:7} = this checkout"; else bad "release was built from ${rel_commit:0:7}, this checkout is ${here:0:7}"; fi
[[ -z "$(git -C "${REPO_ROOT}" status --porcelain -- charts scripts terraform)" ]] && ok "checkout has no uncommitted changes under charts/ scripts/ terraform/" || warn "uncommitted changes under charts/ scripts/ terraform/: the comparison below may differ"

echo "== 5. Installer tarball = git archive of this checkout"
mkdir -p "${W}/inst" "${W}/src"
oras pull "${REGISTRY}/installer:${VERSION}" -o "${W}/inst" >/dev/null 2>&1
tar -xzf "${W}"/inst/straiker-installer-*.tar.gz -C "${W}/inst" 2>/dev/null
git -C "${REPO_ROOT}" archive HEAD scripts terraform charts | tar -x -C "${W}/src"
rm -rf "${W}/src/scripts/release" "${W}/src/scripts/tests" "${W}/src/scripts/protected-clusters.txt"
find "${W}/src" "${W}/inst" -name '*.md' -delete 2>/dev/null
# chart dependencies downloaded at publish time (charts/<n>/charts/*.tgz) are in the tarball, not in git
find "${W}/inst/charts" -path '*/charts/*.tgz' -delete 2>/dev/null
find "${W}/inst/charts" -type d -empty -delete 2>/dev/null
# helm dependency build rewrites Chart.lock (timestamp, digest) at publish time
find "${W}/src/charts" "${W}/inst/charts" -name 'Chart.lock' -delete 2>/dev/null
d="$(diff -rq "${W}/src/scripts" "${W}/inst/scripts" 2>&1 | grep -v 'Only in .*/inst/scripts: release' | head -5)"
d="${d}$(diff -rq "${W}/src/terraform" "${W}/inst/terraform" 2>&1 | grep -v '\.terraform' | head -5)"
if [[ -z "${d}" ]]; then ok "scripts/ and terraform/ identical to git"; else bad "installer differs from git:"; echo "${d}" | sed 's/^/        /'; fi
c="$(diff -rq "${W}/src/charts" "${W}/inst/charts" 2>&1 | head -5)"
if [[ -z "${c}" ]]; then ok "charts/ identical to git"; else bad "charts differ from git (a dependency or lock file can show here):"; echo "${c}" | sed 's/^/        /'; fi

echo
if [[ "${fail}" == 0 ]]; then echo "RESULT: ${VERSION} is complete and matches commit ${here:0:7}."; else echo "RESULT: ${fail} problem(s). Fix them, or publish a new --version."; exit 1; fi
