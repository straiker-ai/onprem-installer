#!/usr/bin/env bash
# Customer-side helper for a Straiker on-prem release delivered through Distr (registry.straiker.ai).
#
#   straiker-release.sh tools                                  # install the command-line tools the install needs
#   straiker-release.sh pull --version <ver> [--dir <dir>]     # download the whole release into one folder
#   straiker-release.sh verify [--dir <dir>]                   # re-check every downloaded file against release.json
#
# pull downloads, into <dir> (default ~/straiker-release/<ver>):
#   release.json   the list of every artifact with its digest (pushed by scripts/release/publish-to-distr.sh)
#   installer/     the installer (scripts, terraform, charts), extracted
#   images/<repo>/<tag>  every container image, as an OCI layout (all platforms)
#   models/<name>  every vLLM model's files
#   charts/        the Helm charts, as .tgz files
# Then: scripts/install-data-layer.sh ... --release-dir <dir> loads the images into your ECR and the models into your
# S3 bucket during the install, instead of copying them from Straiker. See the install guide Straiker sends you.
#
# Distr login: DISTR_USER (your Distr sign-in email) and DISTR_TOKEN (a Distr personal access token) from the
# environment; asked for when not set. The token is never written to disk by this script.
# Safe to re-run: anything already downloaded with the right digest is skipped.
set -euo pipefail

REGISTRY="${STRAIKER_RELEASE_REGISTRY:-registry.straiker.ai/straiker/onprem}"
REGISTRY_HOST="${REGISTRY%%/*}"
BIN_DIR="${STRAIKER_BIN_DIR:-${HOME}/.straiker/bin}"
export PATH="${BIN_DIR}:${PATH}"

ORAS_VERSION=1.2.3
CRANE_VERSION=0.20.3
HELM_VERSION=3.16.4
KUBECTL_VERSION=1.31.4
JQ_VERSION=1.7.1
YQ_VERSION=4.44.3

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n 2,19p "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- tools
os_packages() { # unzip, openssl, htpasswd, python3, tar, curl from the OS package manager
  local sudo=""; [[ "$(id -u)" -ne 0 ]] && sudo="sudo"
  if command -v dnf >/dev/null 2>&1; then
    ${sudo} dnf install -y -q unzip openssl httpd-tools python3 tar gzip tmux git curl-minimal >/dev/null 2>&1 \
      || ${sudo} dnf install -y -q unzip openssl httpd-tools python3 tar gzip tmux git >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    ${sudo} yum install -y -q unzip openssl httpd-tools python3 tar gzip tmux git curl >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    ${sudo} apt-get update -qq >/dev/null && ${sudo} DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      unzip openssl apache2-utils python3 tar gzip curl ca-certificates tmux git >/dev/null
  else
    die "unsupported Linux (no dnf, yum or apt-get). Use Amazon Linux 2023 or Ubuntu."
  fi
}

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

cmd_tools() {
  [[ "$(uname -s)" == Linux ]] || die "'tools' installs Linux binaries. On a Mac: brew install oras crane helm kubectl jq awscli."
  local arch goarch tmp
  arch="$(uname -m)"
  case "${arch}" in x86_64) goarch=amd64 ;; aarch64 | arm64) goarch=arm64 ;; *) die "unsupported CPU '${arch}'" ;; esac
  mkdir -p "${BIN_DIR}"; tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' RETURN

  log "Installing OS packages (unzip, openssl, htpasswd, python3)"
  os_packages

  if ! command -v aws >/dev/null 2>&1; then
    log "Installing AWS CLI v2"
    fetch "https://awscli.amazonaws.com/awscli-exe-linux-${arch/arm64/aarch64}.zip" "${tmp}/awscli.zip"
    unzip -q "${tmp}/awscli.zip" -d "${tmp}"
    "${tmp}/aws/install" --install-dir "${HOME}/.straiker/aws-cli" --bin-dir "${BIN_DIR}" --update >/dev/null
  fi

  log "Installing oras ${ORAS_VERSION}, crane ${CRANE_VERSION}, helm ${HELM_VERSION}, kubectl ${KUBECTL_VERSION}, jq ${JQ_VERSION} into ${BIN_DIR}"
  fetch "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${goarch}.tar.gz" "${tmp}/oras.tgz"
  tar -xzf "${tmp}/oras.tgz" -C "${BIN_DIR}" oras
  fetch "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_${arch/aarch64/arm64}.tar.gz" "${tmp}/crane.tgz"
  tar -xzf "${tmp}/crane.tgz" -C "${BIN_DIR}" crane
  fetch "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${goarch}.tar.gz" "${tmp}/helm.tgz"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}" && mv "${tmp}/linux-${goarch}/helm" "${BIN_DIR}/helm"
  fetch "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${goarch}/kubectl" "${BIN_DIR}/kubectl"
  fetch "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${goarch}" "${BIN_DIR}/jq"
  fetch "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${goarch}" "${BIN_DIR}/yq"
  chmod +x "${BIN_DIR}"/*

  # Make the tools available in every new shell too.
  local line="export PATH=\"${BIN_DIR}:\$PATH\""
  grep -qxF "${line}" "${HOME}/.bashrc" 2>/dev/null || echo "${line}" >> "${HOME}/.bashrc"

  local t missing=()
  for t in aws oras crane helm kubectl jq yq python3 unzip openssl htpasswd curl tmux git; do
    command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "still missing after install: ${missing[*]}"
  log "All tools installed."
}

# ---------------------------------------------------------------- distr login
distr_login() {
  local user="${DISTR_USER:-}" token="${DISTR_TOKEN:-}"
  if [[ -z "${user}" ]]; then read -r -p "Distr sign-in email: " user; fi
  if [[ -z "${token}" ]]; then read -r -s -p "Distr access token (input hidden): " token; echo >&2; fi
  [[ -n "${user}" && -n "${token}" ]] || die "Distr email and access token are both required."
  printf '%s' "${token}" | oras login "${REGISTRY_HOST}" -u "${user}" --password-stdin >/dev/null 2>&1 \
    || die "Distr login failed. Check the email and that the access token is valid (Distr portal > your profile > access tokens)."
  printf '%s' "${token}" | helm registry login "${REGISTRY_HOST}" -u "${user}" --password-stdin >/dev/null 2>&1 \
    || die "Distr login (helm) failed."
  log "Signed in to ${REGISTRY_HOST} as ${user}."
}

# ---------------------------------------------------------------- pull
done_mark() { echo "$1/.straiker-done-${2#sha256:}"; } # marker: this folder holds exactly that digest

pull_one_image() { # repo tag ref digest
  local repo=$1 tag=$2 ref=$3 digest=$4 dir="${DIR}/images/$1/$2"
  [[ -f "$(done_mark "${dir}" "${digest}")" ]] && { echo "  ok    image ${repo}:${tag}"; return; }
  echo "  pull  image ${repo}:${tag}"
  rm -rf "${dir}"; mkdir -p "${dir}"
  oras cp --to-oci-layout "${ref%:*}@${digest}" "${dir}:${tag}" >/dev/null
  touch "$(done_mark "${dir}" "${digest}")"
}

pull_one_model() { # name ref digest
  local name=$1 ref=$2 digest=$3 dir="${DIR}/models/$1"
  [[ -f "$(done_mark "${dir}" "${digest}")" ]] && { echo "  ok    model ${name}"; return; }
  echo "  pull  model ${name} (large: several GB)"
  rm -rf "${dir}"; mkdir -p "${dir}"
  oras pull "${ref%:*}@${digest}" -o "${dir}" >/dev/null
  touch "$(done_mark "${dir}" "${digest}")"
}

pull_one_chart() { # name version ref digest
  local name=$1 ver=$2 ref=$3 digest=$4 out="${DIR}/charts"
  [[ -f "${out}/${name}-${ver}.tgz" && -f "$(done_mark "${out}" "${digest}")" ]] && { echo "  ok    chart ${name} ${ver}"; return; }
  echo "  pull  chart ${name} ${ver}"
  mkdir -p "${out}"
  helm pull "oci://${ref%:*}" --version "${ver}" -d "${out}" >/dev/null
  touch "$(done_mark "${out}" "${digest}")"
}

pull_installer() {
  local ref digest
  ref="$(jq -r '.installer.dest' "${DIR}/release.json")"; digest="$(jq -r '.installer.digest' "${DIR}/release.json")"
  if [[ -f "$(done_mark "${DIR}/installer" "${digest}")" ]]; then echo "  ok    installer"; return; fi
  echo "  pull  installer"
  local tmp; tmp="$(mktemp -d)"
  oras pull "${ref%:*}@${digest}" -o "${tmp}" >/dev/null
  rm -rf "${DIR}/installer"; mkdir -p "${DIR}/installer"
  tar -xzf "${tmp}"/straiker-installer-*.tar.gz -C "${DIR}/installer"
  rm -rf "${tmp}"
  touch "$(done_mark "${DIR}/installer" "${digest}")"
}

cmd_pull() {
  [[ -n "${VERSION}" ]] || die "--version is required (Straiker gives you the version, e.g. onprem-2026.12.0)."
  for t in oras helm jq; do command -v "${t}" >/dev/null 2>&1 || die "'${t}' is not installed. Run: $0 tools"; done
  DIR="${DIR:-${HOME}/straiker-release/${VERSION}}"
  mkdir -p "${DIR}"
  distr_login

  log "Downloading the release list ${REGISTRY}/release:${VERSION}"
  oras pull "${REGISTRY}/release:${VERSION}" -o "${DIR}" >/dev/null \
    || die "could not download release ${VERSION}. Check the version with Straiker, and that your Distr account has access to it."
  [[ -s "${DIR}/release.json" ]] || die "release ${VERSION} has no release.json."
  jq -e '.images and .models and .installer' "${DIR}/release.json" >/dev/null || die "release.json is not valid."

  local free_gb need
  free_gb="$(df -Pk "${DIR}" | awk 'NR==2 {print int($4/1024/1024)}')"
  need="${STRAIKER_RELEASE_MIN_FREE_GB:-250}"
  [[ "${free_gb}" -ge "${need}" ]] || [[ -f "${DIR}/.straiker-complete" ]] \
    || die "only ${free_gb} GB free in ${DIR}; the release needs about ${need} GB. Use a bigger disk or --dir on a bigger volume."

  log "Downloading the installer"
  pull_installer
  log "Downloading $(jq '.images | length' "${DIR}/release.json") container images"
  while IFS=$'\t' read -r repo tag ref digest; do pull_one_image "${repo}" "${tag}" "${ref}" "${digest}"
  done < <(jq -r '.images[] | [.repo, .tag, .dest, .digest] | @tsv' "${DIR}/release.json")
  log "Downloading $(jq '(.charts | length) + (.thirdPartyCharts | length)' "${DIR}/release.json") Helm charts"
  while IFS=$'\t' read -r name ver ref digest; do pull_one_chart "${name}" "${ver}" "${ref}" "${digest}"
  done < <(jq -r '(.charts + .thirdPartyCharts)[] | [.name, .version, .dest, .digest] | @tsv' "${DIR}/release.json")
  log "Downloading $(jq '.models | length' "${DIR}/release.json") AI models (this is the long part)"
  while IFS=$'\t' read -r name ref digest; do pull_one_model "${name}" "${ref}" "${digest}"
  done < <(jq -r '.models[] | [.name, .dest, .digest] | @tsv' "${DIR}/release.json")

  cmd_verify
  touch "${DIR}/.straiker-complete"
  log "Release ${VERSION} is complete in ${DIR} ($(du -sh "${DIR}" | cut -f1))."
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  DIR="${DIR:-$(ls -d "${HOME}"/straiker-release/*/ 2>/dev/null | tail -1)}"; DIR="${DIR%/}"
  [[ -s "${DIR}/release.json" ]] || die "no release.json in '${DIR}'. Run pull first, or pass --dir."
  command -v oras >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || die "'oras' and 'jq' are needed. Run: $0 tools"
  log "Checking every downloaded file against ${DIR}/release.json"
  local bad=0 repo tag digest got name
  while IFS=$'\t' read -r repo tag digest; do
    got="$(oras manifest fetch --oci-layout "${DIR}/images/${repo}/${tag}:${tag}" --descriptor 2>/dev/null | jq -r '.digest' || true)"
    [[ "${got}" == "${digest}" ]] || { echo "  BAD   image ${repo}:${tag} (expected ${digest}, found ${got:-nothing})"; bad=$((bad + 1)); }
  done < <(jq -r '.images[] | [.repo, .tag, .digest] | @tsv' "${DIR}/release.json")
  while IFS=$'\t' read -r name digest; do
    [[ -f "$(done_mark "${DIR}/models/${name}" "${digest}")" ]] && [[ -n "$(ls -A "${DIR}/models/${name}" 2>/dev/null)" ]] \
      || { echo "  BAD   model ${name} (missing or incomplete)"; bad=$((bad + 1)); }
  done < <(jq -r '.models[] | [.name, .digest] | @tsv' "${DIR}/release.json")
  [[ -x "${DIR}/installer/scripts/install-data-layer.sh" ]] || { echo "  BAD   installer (not extracted)"; bad=$((bad + 1)); }
  [[ "${bad}" -eq 0 ]] || die "${bad} item(s) failed the check. Re-run the same pull command: it downloads only what is missing."
  log "Everything matches release.json."
}

# ---------------------------------------------------------------- main
SUB="${1:-}"; [[ $# -gt 0 ]] && shift
VERSION=""; DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; REGISTRY_HOST="${REGISTRY%%/*}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option '$1' (see: $0 --help)" ;;
  esac
done
case "${SUB}" in
  tools) cmd_tools ;;
  pull) cmd_pull ;;
  verify) cmd_verify ;;
  -h | --help | "") usage ;;
  *) die "unknown command '${SUB}' (tools, pull or verify)" ;;
esac
