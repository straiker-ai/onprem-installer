#!/usr/bin/env bash
# Publishes one on-prem release to Distr's OCI registry (registry.straiker.ai), from what already exists:
#   images  : Straiker ECR (charts/straiker-artifact/values.yaml imageMirror list, tags pinned by charts/image-tags.yaml)
#   charts  : this repo's charts/ + the third-party charts the installer uses (versions from install-straiker.sh)
#   installer: this repo's scripts + terraform + charts, as one tarball
#   models  : S3 onprem-artifact-models (charts/straiker-artifact/values.yaml modelSync list)
#   release : release.json listing every artifact with its digest (signed with cosign when --sign-key is given)
# See doc/release-delivery-design.md.
#
#   scripts/release/publish-to-distr.sh --version onprem-2026.12.0                      # plan only (default): lists, pushes nothing
#   scripts/release/publish-to-distr.sh --version onprem-2026.12.0 --sizes --source-profile <p>   # plan + sizes from ECR/S3
#   scripts/release/publish-to-distr.sh --version onprem-2026.12.0 --push --source-profile <p> [--only images,charts,...]
#
# Push needs: crane, helm, oras, aws, yq, jq (cosign for --sign-key). Distr login from DISTR_USER + DISTR_TOKEN
# (a vendor personal access token), or an existing login of crane/helm/oras to the registry. Run the push from an
# EC2 instance in us-east-1: every byte streams through this machine (the models alone are tens of GB).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARTIFACT_VALUES="${REPO_ROOT}/charts/straiker-artifact/values.yaml"
INSTALLER_SH="${REPO_ROOT}/scripts/install-straiker.sh"

VERSION=""
REGISTRY="registry.straiker.ai/straiker/onprem"
SOURCE_PROFILE="${AWS_PROFILE:-}"
SOURCE_REGION="us-east-1"
WORK_DIR=""
MODE="plan"
SIZES=false
ONLY="images,charts,installer,models,release"
SIGN_KEY=""

usage() { sed -n 2,19p "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --source-profile) SOURCE_PROFILE="${2:-}"; shift 2 ;;
    --source-region) SOURCE_REGION="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --push) MODE="push"; shift ;;
    --sizes) SIZES=true; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --sign-key) SIGN_KEY="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "ERROR: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "${VERSION}" ]] || { echo "ERROR: --version is required (e.g. onprem-2026.12.0)." >&2; exit 2; }
[[ "${VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo "ERROR: --version must be a valid OCI tag." >&2; exit 2; }
# Guard: on-prem artifacts live only under their own prefix, so nothing already in Distr (other products) is touched.
[[ "${REGISTRY}" == */onprem || "${REGISTRY}" == */onprem/* ]] \
  || { echo "ERROR: --registry must end in /onprem (or a sub-path) so existing Distr artifacts are never overwritten." >&2; exit 2; }
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/dist/release/${VERSION}}"
REGISTRY_HOST="${REGISTRY%%/*}"
want() { [[ ",${ONLY}," == *",$1,"* ]]; }
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
aws_src() { aws ${SOURCE_PROFILE:+--profile "${SOURCE_PROFILE}"} --region "${SOURCE_REGION}" "$@"; }
human() { awk -v b="$1" 'BEGIN{ s="B KiB MiB GiB TiB"; split(s,u," "); i=1; while (b>=1024 && i<5) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'; }

need=(yq jq)
[[ "${MODE}" == push || "${SIZES}" == true ]] && need+=(crane aws)
[[ "${MODE}" == push ]] && need+=(helm oras)
[[ -n "${SIGN_KEY}" ]] && need+=(cosign)
for c in "${need[@]}"; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' is required." >&2; exit 2; }; done

mkdir -p "${WORK_DIR}"
LIST="${WORK_DIR}/list.json"

# ---------------------------------------------------------------- 1. what goes into the release
# Third-party charts the installer installs from the internet today (versions as pinned in install-straiker.sh).
tp_ver() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "${INSTALLER_SH}" | head -1; }
third_party_charts() {
  jq -n --arg k "$(tp_ver KARPENTER_VERSION)" --arg a "$(tp_ver ALB_CONTROLLER_VERSION)" \
    --arg e "$(tp_ver EXTERNAL_DNS_VERSION)" --arg s "$(tp_ver ESO_VERSION)" '[
    {name:"karpenter", version:$k, from:"oci://public.ecr.aws/karpenter/karpenter"},
    {name:"aws-load-balancer-controller", version:$a, repo:"https://aws.github.io/eks-charts"},
    {name:"external-dns", version:$e, repo:"https://kubernetes-sigs.github.io/external-dns/"},
    {name:"external-secrets", version:$s, repo:"https://charts.external-secrets.io"}
  ]'
}

build_list() {
  local images models charts
  # repo = the image's path in the customer's ECR ("<prefix>/<repo>"), the same destRepository the in-cluster mirror uses.
  # Bifrost: Straiker's ECR copy is amd64-only and the shared pool is Graviton, so the release takes the multi-arch
  # upstream index instead (the same fix install-straiker.sh's ensure_multiarch_images applies after the mirror).
  images="$(yq -o=json '.imageMirror.images' "${ARTIFACT_VALUES}" | jq --arg reg "${REGISTRY}" '[.[] |
      (.source | sub("\\s+$"; "")) as $src
      | (.destRepository // ($src | sub("^[^/]+/onprem-base/"; "") | sub("^[^/]+/"; ""))) as $repo
      | (.tag | tostring) as $tag | {
      source: ((if $repo == "maximhq/bifrost" then "docker.io/maximhq/bifrost" else $src end) + ":" + $tag),
      repo: $repo, tag: $tag,
      dest: ($reg + "/images/" + $repo + ":" + $tag),
      sku: (.sku // "base")
    }]')"
  models="$(yq -o=json '.modelSync' "${ARTIFACT_VALUES}" | jq --arg reg "${REGISTRY}" '. as $m | [.models[] | {
      name: .destPath,
      source: ("s3://" + $m.sourceBucket + "/" + .path),
      dest: ($reg + "/models/" + .destPath + ":" + (.path | split("/") | last))
    }]')"
  charts="$(for f in "${REPO_ROOT}"/charts/*/Chart.yaml; do
      yq -o=json '.' "$f" | jq --arg d "$(dirname "$f")" '{name: .name, version: (.version | tostring), path: $d}'
    done | jq -s --arg reg "${REGISTRY}" '[.[] | . + {dest: ($reg + "/charts/" + .name + ":" + .version)}]')"
  jq -n --arg v "${VERSION}" --arg reg "${REGISTRY}" --argjson images "${images}" --argjson models "${models}" \
    --argjson charts "${charts}" --argjson tp "$(third_party_charts)" '{
      version: $v, registry: $reg,
      installer: {dest: ($reg + "/installer:" + $v)},
      images: $images, charts: $charts,
      thirdPartyCharts: [$tp[] | . + {dest: ($reg + "/charts/" + .name + ":" + .version)}],
      models: $models
    }' > "${LIST}"
}

# ---------------------------------------------------------------- 2. plan (and sizes)
image_size() { # compressed bytes of every platform in the image (index: sum over manifests)
  local ref="$1" m
  m="$(crane manifest "${ref}" 2>/dev/null)" || { echo -1; return; }
  if jq -e '.manifests' >/dev/null <<<"${m}"; then
    local total=0 d s
    for d in $(jq -r '.manifests[] | select(.platform.os != "unknown") | .digest' <<<"${m}"); do
      s="$(crane manifest "${ref%:*}@${d}" | jq '[.layers[].size] | add + 0')"; total=$((total + s))
    done
    echo "${total}"
  else
    jq '[.layers[].size] | add + 0' <<<"${m}"
  fi
}
model_size() { aws_src s3 ls --recursive --summarize "$1/" 2>/dev/null | awk '/Total Size/ {print $3}' || echo -1; }

plan() {
  local n_img n_chart n_tp n_mod total=0 s
  n_img="$(jq '.images | length' "${LIST}")"; n_chart="$(jq '.charts | length' "${LIST}")"
  n_tp="$(jq '.thirdPartyCharts | length' "${LIST}")"; n_mod="$(jq '.models | length' "${LIST}")"
  echo "Release ${VERSION} -> ${REGISTRY}"
  echo "  images ${n_img}, charts ${n_chart} (+${n_tp} third-party), models ${n_mod}, installer 1, release manifest 1"
  if [[ "${SIZES}" == true ]]; then
    aws_src ecr get-login-password | crane auth login "$(jq -r '.images[0].source' "${LIST}" | cut -d/ -f1)" -u AWS --password-stdin >/dev/null
  fi
  echo; echo "IMAGES (source -> dest)"
  while IFS=$'\t' read -r src dst; do
    if [[ "${SIZES}" == true ]]; then s="$(image_size "${src}")"; [[ "${s}" -ge 0 ]] && total=$((total + s))
      printf '  %-12s %s\n      -> %s\n' "$([[ "${s}" -ge 0 ]] && human "${s}" || echo MISSING)" "${src}" "${dst}"
    else printf '  %s\n      -> %s\n' "${src}" "${dst}"; fi
  done < <(jq -r '.images[] | [.source, .dest] | @tsv' "${LIST}")
  echo; echo "MODELS (source -> dest)"
  while IFS=$'\t' read -r src dst; do
    if [[ "${SIZES}" == true ]]; then s="$(model_size "${src}")"; [[ "${s:--1}" -ge 0 ]] && total=$((total + s))
      printf '  %-12s %s\n      -> %s\n' "$([[ "${s:--1}" -ge 0 ]] && human "${s}" || echo MISSING)" "${src}" "${dst}"
    else printf '  %s\n      -> %s\n' "${src}" "${dst}"; fi
  done < <(jq -r '.models[] | [.source, .dest] | @tsv' "${LIST}")
  echo; echo "CHARTS"; jq -r '.charts[] | "  \(.name) \(.version)"' "${LIST}"
  echo "THIRD-PARTY CHARTS"; jq -r '.thirdPartyCharts[] | "  \(.name) \(.version)  (from \(.from // .repo))"' "${LIST}"
  [[ "${SIZES}" == true ]] && { echo; echo "TOTAL (images compressed, all platforms + models): $(human "${total}")"; }
  echo
  echo "NOT YET IN THE RELEASE (still pulled from the internet by the installer; see design doc 8.1):"
  echo "  - images of the third-party charts above (Karpenter, ALB controller, external-dns, ESO): need chart rendering"
  echo "  - cert-manager chart: installer does not pin a version (install-straiker.sh phase edge)"
  echo "  - OpenTofu binary, providers and registry modules"
  echo "  - crane and rclone job images (gcr.io / docker.io), only used by the old in-cluster copy jobs"
  echo
  echo "Full list: ${LIST}"
}

# ---------------------------------------------------------------- 3. push
distr_login() {
  if [[ -n "${DISTR_USER:-}" && -n "${DISTR_TOKEN:-}" ]]; then
    printf '%s' "${DISTR_TOKEN}" | crane auth login "${REGISTRY_HOST}" -u "${DISTR_USER}" --password-stdin >/dev/null
    printf '%s' "${DISTR_TOKEN}" | helm registry login "${REGISTRY_HOST}" -u "${DISTR_USER}" --password-stdin >/dev/null
    printf '%s' "${DISTR_TOKEN}" | oras login "${REGISTRY_HOST}" -u "${DISTR_USER}" --password-stdin >/dev/null
  else
    log "DISTR_USER/DISTR_TOKEN not set: using existing crane/helm/oras logins to ${REGISTRY_HOST}."
  fi
}

push_images() {
  aws_src ecr get-login-password | crane auth login "$(jq -r '.images[0].source' "${LIST}" | cut -d/ -f1)" -u AWS --password-stdin >/dev/null
  local src dst
  while IFS=$'\t' read -r src dst; do
    if crane digest "${dst}" >/dev/null 2>&1 && [[ "$(crane digest "${dst}")" == "$(crane digest "${src}")" ]]; then
      log "skip  ${dst} (same digest already there)"; continue
    fi
    log "copy  ${src} -> ${dst}"
    crane copy "${src}" "${dst}"
  done < <(jq -r '.images[] | [.source, .dest] | @tsv' "${LIST}")
}

push_charts() {
  local out="${WORK_DIR}/charts" path name ver
  mkdir -p "${out}"
  while IFS=$'\t' read -r name ver path; do
    log "chart ${name} ${ver}"
    helm package "${path}" -d "${out}" >/dev/null
    helm push "${out}/${name}-${ver}.tgz" "oci://${REGISTRY}/charts" >/dev/null
  done < <(jq -r '.charts[] | [.name, .version, .path] | @tsv' "${LIST}")
  local from repo
  while IFS=$'\t' read -r name ver from repo; do
    log "chart ${name} ${ver} (third-party)"
    if [[ -n "${from}" ]]; then helm pull "${from}" --version "${ver}" -d "${out}" >/dev/null
    else helm pull "${name}" --repo "${repo}" --version "${ver}" -d "${out}" >/dev/null; fi
    helm push "${out}/${name}-${ver}.tgz" "oci://${REGISTRY}/charts" >/dev/null
  done < <(jq -r '.thirdPartyCharts[] | [.name, .version, (.from // ""), (.repo // "")] | @tsv' "${LIST}")
}

push_installer() {
  local tarball="${WORK_DIR}/straiker-installer-${VERSION}.tar.gz"
  log "pack  installer -> ${tarball}"
  tar -czf "${tarball}" -C "${REPO_ROOT}" \
    --exclude='.terraform' --exclude='.terraform.lock.hcl.bak' --exclude='*.tfstate*' --exclude='.terragrunt-cache' \
    --exclude='scripts/release' --exclude='scripts/tests' --exclude='scripts/protected-clusters.txt' --exclude='*/*.md' \
    scripts terraform charts LICENSE THIRD_PARTY_LICENSES.md
  log "push  installer -> $(jq -r '.installer.dest' "${LIST}")"
  (cd "${WORK_DIR}" && oras push "$(jq -r '.installer.dest' "${LIST}")" \
    --artifact-type application/vnd.straiker.onprem.installer.v1 \
    "straiker-installer-${VERSION}.tar.gz:application/vnd.straiker.onprem.installer.layer.v1.tar+gzip" >/dev/null)
}

push_models() {
  local name src dst dir
  while IFS=$'\t' read -r name src dst; do
    if crane digest "${dst}" >/dev/null 2>&1; then log "skip  model ${dst} (tag already there)"; continue; fi
    dir="${WORK_DIR}/models/${name}"
    log "fetch model ${src} -> ${dir}"
    mkdir -p "${dir}"
    aws_src s3 sync "${src}/" "${dir}/" --only-show-errors
    log "push  model ${dst}"
    (cd "${dir}" && find . -type f ! -name '.*' | sed 's|^\./||' | sort \
      | xargs oras push "${dst}" --artifact-type application/vnd.straiker.onprem.model.v1 >/dev/null)
  done < <(jq -r '.models[] | [.name, .source, .dest] | @tsv' "${LIST}")
}

push_release() {
  local manifest="${WORK_DIR}/release.json"
  log "digest every artifact for the release manifest"
  jq -c '.images[]' "${LIST}" >/dev/null
  local tmp; tmp="$(mktemp)"
  jq -r '[.installer.dest] + [.images[].dest] + [.charts[].dest] + [.thirdPartyCharts[].dest] + [.models[].dest] | .[]' "${LIST}" \
    | while read -r ref; do printf '%s\t%s\n' "${ref}" "$(crane digest "${ref}")"; done > "${tmp}"
  jq -R -s --slurpfile list "${LIST}" '
    (split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add) as $d
    | $list[0] | del(.charts[].path)
    | .installer.digest = $d[.installer.dest]
    | .images |= map(.digest = $d[.dest]) | .charts |= map(.digest = $d[.dest])
    | .thirdPartyCharts |= map(.digest = $d[.dest]) | .models |= map(.digest = $d[.dest])
    | .createdAt = (now | todate) | .gitCommit = env.GIT_COMMIT' "${tmp}" > "${manifest}"
  rm -f "${tmp}"
  local files=("release.json:application/vnd.straiker.onprem.release.v1+json")
  if [[ -n "${SIGN_KEY}" ]]; then
    cosign sign-blob --yes --key "${SIGN_KEY}" --output-signature "${WORK_DIR}/release.json.sig" "${manifest}" >/dev/null
    files+=("release.json.sig:application/vnd.straiker.onprem.release.sig.v1")
  else
    log "WARN  release manifest is NOT signed (no --sign-key)."
  fi
  log "push  release manifest -> ${REGISTRY}/release:${VERSION}"
  (cd "${WORK_DIR}" && oras push "${REGISTRY}/release:${VERSION}" --artifact-type application/vnd.straiker.onprem.release.v1 "${files[@]}" >/dev/null)
}

build_list
if [[ "${MODE}" == plan ]]; then plan; exit 0; fi

export GIT_COMMIT; GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain -- charts scripts terraform 2>/dev/null)" ]]; then
  log "WARN  uncommitted changes under charts/ scripts/ terraform/: the release will not match commit ${GIT_COMMIT}."
fi
distr_login
want images && push_images
want charts && push_charts
want installer && push_installer
want models && push_models
want release && push_release
log "done  ${REGISTRY}/release:${VERSION}"
