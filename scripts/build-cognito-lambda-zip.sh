#!/usr/bin/env bash
# Build the Cognito trigger Lambdas for `install-data-layer.sh --saas-auth --cognito-lambda-zip <zip>`.
#
# The triggers are foundation's environment-api (pre-authentication, pre-sign-up, pre-token-generation and the three CUSTOM_AUTH
# handlers): one zip, one CommonJS bundle per handler. This builds it the way foundation's own publish script does
# (environment-api/scripts/publish-lambda-artifacts.sh), without publishing anything:
#
#   scripts/build-cognito-lambda-zip.sh <path to foundation>/environment-api [OUT.zip]
#
# Needs pnpm and zip. Writes OUT.zip (default ./cognito-lambda-<foundation commit>.zip) and prints its path and sha256.
# --skip-build zips the existing dist/lambda as it is (no pnpm; only when you know it is current).
set -euo pipefail

SKIP_BUILD=false
ARGS=()
for a in "$@"; do
  case "${a}" in
    --skip-build) SKIP_BUILD=true ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ARGS+=("${a}") ;;
  esac
done
[[ ${#ARGS[@]} -ge 1 ]] || { sed -n '2,13p' "$0" >&2; exit 2; }

src="$(cd "${ARGS[0]}" && pwd)"
[[ -f "${src}/package.json" && -f "${src}/build.ts" ]] || { echo "ERROR: ${src} is not foundation's environment-api (no package.json / build.ts)." >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "ERROR: zip is required." >&2; exit 1; }

sha="$(git -C "${src}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
dirty="$(git -C "${src}" status --porcelain -- . 2>/dev/null | head -1 || true)"
[[ -z "${dirty}" ]] || echo "WARNING: ${src} has uncommitted changes; the zip does not match commit ${sha} exactly." >&2

out="${ARGS[1]:-$PWD/cognito-lambda-${sha}.zip}"
case "${out}" in /*) ;; *) out="$PWD/${out}" ;; esac

cd "${src}"
if [[ "${SKIP_BUILD}" != true ]]; then
  command -v pnpm >/dev/null 2>&1 || { echo "ERROR: pnpm is required (or pass --skip-build to zip the existing dist/lambda)." >&2; exit 1; }
  pnpm install --frozen-lockfile
  pnpm build
fi
[[ -f dist/lambda/pre-token-generation.js ]] || { echo "ERROR: dist/lambda has no pre-token-generation.js: the build did not produce the handlers." >&2; exit 1; }

rm -f "${out}"
(cd dist/lambda && zip -qr -X "${out}" . -x '*.test.js')
# Read the listing first: grep -q exiting early would SIGPIPE unzip and fail the pipe under pipefail.
listing="$(unzip -l "${out}")"
for h in pre-authentication pre-sign-up pre-token-generation define-auth-challenge create-auth-challenge verify-auth-challenge; do
  [[ "${listing}" == *" ${h}.js"* ]] || { echo "ERROR: ${h}.js is missing from the zip." >&2; exit 1; }
done
echo "zip:    ${out}"
echo "commit: ${sha}"
if command -v sha256sum >/dev/null 2>&1; then echo "sha256: $(sha256sum "${out}" | cut -d' ' -f1)"; else echo "sha256: $(shasum -a 256 "${out}" | cut -d' ' -f1)"; fi
