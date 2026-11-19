#!/usr/bin/env bash
# Manage the OAuth clients (client_credentials) that API users present to the API gateway's token endpoint:
#   POST https://api.<domain>/auth/token   grant_type=client_credentials, client_id, client_secret (body or HTTP Basic)
#
#   scripts/api-client.sh list
#   scripts/api-client.sh show   [NAME]          print the client id, and the secret (needs --reveal)
#   scripts/api-client.sh add    NAME            create a client and print its secret once
#   scripts/api-client.sh rotate [NAME]          new secret for NAME (default: the installer's first client, 'onprem-client')
#   scripts/api-client.sh remove NAME            delete an additional client (the first client cannot be removed, only rotated)
#   scripts/api-client.sh token  [NAME]          request a token and print its first characters (a quick end-to-end check)
#
# Options: --namespace NS (default straiker)  --kubeconfig FILE  --url https://api.<domain> (token; default: the gateway ingress host)
#          --reveal (show prints the secret)  --yes (skip the confirmation)
#
# The first client 'onprem-client' lives in Secret api-gateway-oauth (created by the installer). Additional clients live in Secret
# api-gateway-oauth-clients (one key per client, the value is its secret); the installer re-applies them whenever it installs the
# gateway. After a change this script applies it to the running gateway (helm upgrade --reuse-values, one gateway restart).
# Secrets are never written to disk or the shell history; add/rotate print the new secret exactly once.
set -uo pipefail

NS="straiker"
KCFG=""
REVEAL=false
YES=false
URL=""
FIRST_CLIENT_SECRET="api-gateway-oauth"
EXTRA_SECRET="api-gateway-oauth-clients"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${SCRIPT_DIR}/../charts/platform-api-gateway"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,19p' "$0"; }

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS=${2:-}; shift 2 ;;
    --kubeconfig) KCFG=${2:-}; shift 2 ;;
    --url) URL=${2:-}; shift 2 ;;
    --reveal) REVEAL=true; shift ;;
    --yes) YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ ${#ARGS[@]} -ge 1 ]] || { usage; exit 2; }
CMD="${ARGS[0]}"
NAME="${ARGS[1]:-}"

command -v kubectl >/dev/null 2>&1 || die "kubectl is required."
k() { if [[ -n "${KCFG}" ]]; then kubectl --kubeconfig "${KCFG}" -n "${NS}" "$@"; else kubectl -n "${NS}" "$@"; fi; }
h() { if [[ -n "${KCFG}" ]]; then helm --kubeconfig "${KCFG}" -n "${NS}" "$@"; else helm -n "${NS}" "$@"; fi; }

ctx="$(if [[ -n "${KCFG}" ]]; then kubectl --kubeconfig "${KCFG}" config current-context; else kubectl config current-context; fi 2>/dev/null)"
echo "Cluster context: ${ctx:-unknown}  namespace: ${NS}" >&2
k get secret "${FIRST_CLIENT_SECRET}" >/dev/null 2>&1 || die "Secret ${FIRST_CLIENT_SECRET} not found in namespace ${NS}: wrong cluster, or the api-gateway is not installed."

first_id() { k get secret "${FIRST_CLIENT_SECRET}" -o jsonpath='{.data.client-id}' | base64 -d; }
first_secret() { k get secret "${FIRST_CLIENT_SECRET}" -o jsonpath='{.data.client-secret}' | base64 -d; }
extra_names() { k get secret "${EXTRA_SECRET}" -o json 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join(sorted(json.load(sys.stdin).get("data",{}))))
except Exception: pass'; }
extra_secret() { k get secret "${EXTRA_SECRET}" -o jsonpath="{.data.${1}}" 2>/dev/null | base64 -d; }
new_secret() { openssl rand -hex 32; }

valid_name() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{1,38})[a-z0-9]$ ]]; }

confirm() {
  [[ "${YES}" == true ]] && return 0
  read -r -p "$1 Continue? [y/N] " a
  [[ "${a}" == "y" || "${a}" == "Y" ]]
}

# Push the current set of clients into the running gateway: the first client plus every key of the extra Secret.
apply() {
  command -v helm >/dev/null 2>&1 || die "helm is required."
  [[ -d "${CHART}" ]] || die "Chart not found at ${CHART} (run this script from the installer bundle)."
  local -a sets=(--set-string "straiker.apiGateway.oauth.inmemory.clients[0].client-id=$(first_id)"
    --set-string "straiker.apiGateway.oauth.inmemory.clients[0].client-secret=$(first_secret)")
  local i=1 n
  while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    sets+=(--set-string "straiker.apiGateway.oauth.inmemory.clients[${i}].client-id=${n}"
      --set-string "straiker.apiGateway.oauth.inmemory.clients[${i}].client-secret=$(extra_secret "${n}")")
    i=$((i + 1))
  done < <(extra_names)
  echo "Applying ${i} client(s) to the gateway (one rolling restart)..." >&2
  h upgrade api-gateway "${CHART}" --reuse-values --wait --timeout 10m "${sets[@]}" >/dev/null || die "helm upgrade failed; the Secret was changed but the gateway still has the old clients."
}

case "${CMD}" in
  list)
    echo "$(first_id)  (installer's first client; rotate with: $0 rotate)"
    extra_names
    ;;
  show)
    NAME="${NAME:-$(first_id)}"
    echo "client_id:     ${NAME}"
    if [[ "${REVEAL}" == true ]]; then
      if [[ "${NAME}" == "$(first_id)" ]]; then s="$(first_secret)"; else s="$(extra_secret "${NAME}")"; fi
      [[ -n "${s}" ]] || die "No client named '${NAME}'."
      echo "client_secret: ${s}"
    else
      echo "client_secret: (hidden; add --reveal to print it)"
    fi
    ;;
  add)
    valid_name "${NAME}" || die "Client name must be 3-40 characters: lower-case letters, digits, '-'; not starting or ending with '-'."
    [[ "${NAME}" != "$(first_id)" ]] || die "'${NAME}' is the installer's first client; use rotate."
    extra_names | grep -qx "${NAME}" && die "Client '${NAME}' already exists; use rotate."
    confirm "This adds client '${NAME}' to the gateway and restarts it." || exit 1
    k get secret "${EXTRA_SECRET}" >/dev/null 2>&1 || k create secret generic "${EXTRA_SECRET}" >/dev/null || die "Cannot create Secret ${EXTRA_SECRET}."
    s="$(new_secret)"
    k patch secret "${EXTRA_SECRET}" --type merge -p "{\"stringData\":{\"${NAME}\":\"${s}\"}}" >/dev/null || die "Cannot store the client."
    apply
    echo "client_id:     ${NAME}"
    echo "client_secret: ${s}   (shown once; store it in your secret manager)"
    ;;
  rotate)
    NAME="${NAME:-$(first_id)}"
    confirm "This replaces the secret of client '${NAME}': everything using the old secret stops working, and the gateway restarts." || exit 1
    s="$(new_secret)"
    if [[ "${NAME}" == "$(first_id)" ]]; then
      k patch secret "${FIRST_CLIENT_SECRET}" --type merge -p "{\"stringData\":{\"client-secret\":\"${s}\"}}" >/dev/null || die "Cannot store the secret."
    else
      extra_names | grep -qx "${NAME}" || die "No client named '${NAME}'."
      k patch secret "${EXTRA_SECRET}" --type merge -p "{\"stringData\":{\"${NAME}\":\"${s}\"}}" >/dev/null || die "Cannot store the secret."
    fi
    apply
    echo "client_id:     ${NAME}"
    echo "client_secret: ${s}   (shown once; store it in your secret manager)"
    ;;
  remove)
    [[ -n "${NAME}" ]] || die "Give the client name."
    [[ "${NAME}" != "$(first_id)" ]] || die "The installer's first client cannot be removed, only rotated."
    extra_names | grep -qx "${NAME}" || die "No client named '${NAME}'."
    confirm "This deletes client '${NAME}' and restarts the gateway." || exit 1
    k patch secret "${EXTRA_SECRET}" --type merge -p "{\"data\":{\"${NAME}\":null}}" >/dev/null || die "Cannot remove the client."
    apply
    echo "Removed '${NAME}'."
    ;;
  token)
    NAME="${NAME:-$(first_id)}"
    if [[ "${NAME}" == "$(first_id)" ]]; then s="$(first_secret)"; else s="$(extra_secret "${NAME}")"; fi
    [[ -n "${s}" ]] || die "No client named '${NAME}'."
    host="${URL}"
    # The gateway's public host: the ingress rule that starts with "api." (xalb), else the Service-based baseUrl value.
    [[ -n "${host}" ]] || host="$(k get ingress -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' 2>/dev/null | tr ' ' '\n' | grep '^api\.' | head -1)"
    [[ -n "${host}" ]] || die "Cannot find the gateway host; pass --url https://api.<domain>."
    [[ "${host}" == http* ]] || host="https://${host}"
    code="$(curl -s -m 20 -o /tmp/.api-client-token.$$ -w '%{http_code}' -X POST "${host%/}/auth/token" -u "${NAME}:${s}" -d grant_type=client_credentials)"
    echo "POST ${host%/}/auth/token -> HTTP ${code}"
    python3 - "/tmp/.api-client-token.$$" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    t = d.get("access_token", "")
    print("access_token:", (t[:12] + "...") if t else "(none)", " expires_in:", d.get("expires_in"), " error:", d.get("error"))
except Exception as e:
    print("unreadable response:", e)
PY
    rm -f "/tmp/.api-client-token.$$"
    ;;
  *) usage; exit 2 ;;
esac
