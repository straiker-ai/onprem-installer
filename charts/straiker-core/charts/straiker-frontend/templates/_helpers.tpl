{{/* ── Frontend (formerly "control") ─────────────────────────────────────
Rebuilt against ~/straiker/frontend/onprem/docker-compose.yaml's "frontend"
service as the authoritative reference, not the old straiker-control chart. */}}

{{- define "frontend.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "frontend.secretName" -}}straiker-secrets{{- end }}

{{- define "frontend.authSecretName" -}}straiker-frontend-auth{{- end }}

{{- define "frontend.image" -}}
{{- $f := .Values.frontend -}}
{{- $repo := required "frontend.image.repository is required" $f.image.repository -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") $repo $f.image.tag -}}
{{- else -}}
{{- printf "%s:%s" $repo $f.image.tag -}}
{{- end -}}
{{- end }}

{{/* Falls back to the main frontend image when no separate migrate image is set. */}}
{{- define "frontend.migrateImage" -}}
{{- $f := .Values.frontend -}}
{{- $repo := $f.dbMigrate.image.repository | default (required "frontend.image.repository is required" $f.image.repository) -}}
{{- $tag := $f.dbMigrate.image.tag | default $f.image.tag -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") $repo $tag -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end }}

{{/* library/postgres image used to run bootstrap.sql via psql — a fixed,
independent image rather than falling back to frontend's own (that one's a
straiker/frontend-migrate Liquibase image, not something with a psql client). */}}
{{- define "frontend.bootstrapImage" -}}
{{- $f := .Values.frontend -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") $f.bootstrap.image.repository $f.bootstrap.image.tag -}}
{{- else -}}
{{- printf "%s:%s" $f.bootstrap.image.repository $f.bootstrap.image.tag -}}
{{- end -}}
{{- end }}

{{/* Matches glauth-configmap.yaml's seeded admin user's `mail` field exactly
— that's the OIDC email claim dex returns on login, which this bootstrap row
must match for the bundled local IdP's admin login to work out of the box. */}}
{{- define "frontend.bootstrapAdminEmail" -}}
{{- .Values.frontend.bootstrap.adminEmail | default (printf "admin@%s" .Values.global.appDomain) -}}
{{- end }}

{{- define "frontend.dbPasswordSecretName" -}}
{{- .Values.frontend.db.passwordSecret.name | default "straiker-postgres-secret" -}}
{{- end }}

{{- define "frontend.dbPasswordSecretKey" -}}
{{- .Values.frontend.db.passwordSecret.key | default "POSTGRES_PASSWORD_PLATFORM" -}}
{{- end }}

{{/* Defaults to charts/straiker-system's own postgres Service, in global.infraNamespace. */}}
{{- define "frontend.dbHost" -}}
{{- if .Values.frontend.db.host -}}
{{- .Values.frontend.db.host -}}
{{- else -}}
{{- printf "straiker-postgres.%s.svc.cluster.local" .Values.global.infraNamespace -}}
{{- end -}}
{{- end }}

{{/* Defaults to charts/straiker-system's own opensearch, in global.infraNamespace. */}}
{{- define "frontend.opensearchUrl" -}}
{{- if .Values.frontend.opensearch.url -}}
{{- .Values.frontend.opensearch.url -}}
{{- else -}}
{{- printf "http://opensearch-cluster-master.%s.svc.cluster.local:9200" .Values.global.infraNamespace -}}
{{- end -}}
{{- end }}

{{- define "frontend.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-frontend
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Falls back to the parent chart's global.sharedNodeSelector. */}}
{{- define "frontend.nodeSelector" -}}
{{- .Values.frontend.nodeSelector | default .Values.global.sharedNodeSelector | toYaml -}}
{{- end }}

{{/* Public origin the app is actually reached at — used for both frontend's
own ORIGIN env var and dex's OIDC redirect URI, so they can never drift out
of sync with each other. Defaults to Caddy's own routed host (global.appDomain)
on caddy.httpsPort — not the standard 443, since there's no ingress yet and
port-forwarding straight to Caddy's Service is the only way to reach this
today; 8443 needs no sudo to bind locally, unlike 443. Override frontend.origin
if that's not how it's being reached (e.g. a real port-forward to 443, or a
customer's own ingress later). */}}
{{- define "frontend.origin" -}}
{{- .Values.frontend.origin | default (printf "https://app.%s:%v" .Values.global.appDomain .Values.caddy.httpsPort) -}}
{{- end }}

{{/* ── glauth (local LDAP directory backing dex) ─────────────────────────
Bundled default IdP so a fresh install has working login without the
customer bringing their own OIDC provider on day one — same components as
~/straiker/frontend/onprem/docker-compose.yaml's glauth/dex services. */}}

{{- define "glauth.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "glauth.image" -}}
{{- $g := .Values.glauth -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") $g.image.repository $g.image.tag -}}
{{- else -}}
{{- printf "%s:%s" $g.image.repository $g.image.tag -}}
{{- end -}}
{{- end }}

{{- define "glauth.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: glauth
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "glauth.nodeSelector" -}}
{{- .Values.glauth.nodeSelector | default .Values.global.sharedNodeSelector | toYaml -}}
{{- end }}

{{/* ── dex (local OIDC provider, LDAP-backed by glauth) ──────────────────── */}}

{{- define "dex.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "dex.image" -}}
{{- $d := .Values.dex -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") $d.image.repository $d.image.tag -}}
{{- else -}}
{{- printf "%s:%s" $d.image.repository $d.image.tag -}}
{{- end -}}
{{- end }}

{{- define "dex.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: dex
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "dex.nodeSelector" -}}
{{- .Values.dex.nodeSelector | default .Values.global.sharedNodeSelector | toYaml -}}
{{- end }}

{{/* In-cluster issuer URL — must match dex's own config.yaml `issuer` field
exactly (OIDC requires the discovery doc's issuer to match what consumers are
told). No ingress yet, so this is a plain in-cluster ClusterIP address rather
than the docker-compose reference's public dex.<domain> host. */}}
{{- define "dex.issuerUrl" -}}
{{- printf "http://dex-service.%s.svc.cluster.local:%v" (include "dex.namespace" .) .Values.dex.service.port -}}
{{- end }}

{{/* Caddy-routed, browser-reachable dex address (see caddy-configmap.yaml's
"dex.<appDomain>" site) — needed ONLY for the authorization endpoint below,
since that's the one the browser is redirected to directly and can't resolve
a .svc.cluster.local address. The reverse is also true: token/jwks (called
server-to-server by frontend's own backend pod) must stay on dex.issuerUrl,
since the cluster has no DNS record for this synthetic appDomain host. */}}
{{- define "dex.publicUrl" -}}
{{- printf "https://dex.%s:%v" .Values.global.appDomain .Values.caddy.httpsPort -}}
{{- end }}

{{/* ── frontend OIDC — each falls back to the bundled dex/glauth stack;
override all of them together (and set dex.enabled/glauth.enabled: false) to
point at a customer's own external IdP instead. */}}

{{- define "frontend.oidcIssuer" -}}
{{- .Values.frontend.oidc.issuer | default (include "dex.issuerUrl" .) -}}
{{- end }}

{{- define "frontend.oidcClientId" -}}
{{- .Values.frontend.oidc.clientId | default .Values.dex.staticClient.id -}}
{{- end }}

{{- define "frontend.oidcClientSecret" -}}
{{- .Values.frontend.oidc.clientSecret | default .Values.dex.staticClient.secret -}}
{{- end }}

{{- define "frontend.oidcAuthorizationEndpoint" -}}
{{- .Values.frontend.oidc.authorizationEndpoint | default (printf "%s/auth" (include "dex.publicUrl" .)) -}}
{{- end }}

{{- define "frontend.oidcTokenEndpoint" -}}
{{- .Values.frontend.oidc.tokenEndpoint | default (printf "%s/token" (include "dex.issuerUrl" .)) -}}
{{- end }}

{{- define "frontend.oidcJwksUri" -}}
{{- .Values.frontend.oidc.jwksUri | default (printf "%s/keys" (include "dex.issuerUrl" .)) -}}
{{- end }}

{{/* ── Caddy (TLS termination + host-based routing to frontend/dex) ──────
Deployed as a real reverse-proxy rather than a K8s Ingress resource — Ingress
does nothing without a pre-existing Ingress controller on the cluster, which
can't be assumed on a customer's bring-your-own cluster (same class of gap as
Karpenter/StorageClass elsewhere in this project). Self-signed via `tls
internal`, matching docker-compose's own local-dev framing; a customer
wanting real certs would need to extend this later. */}}

{{- define "caddy.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "caddy.image" -}}
{{- $c := .Values.caddy -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") $c.image.repository $c.image.tag -}}
{{- else -}}
{{- printf "%s:%s" $c.image.repository $c.image.tag -}}
{{- end -}}
{{- end }}

{{- define "caddy.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: caddy
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "caddy.nodeSelector" -}}
{{- .Values.caddy.nodeSelector | default .Values.global.sharedNodeSelector | toYaml -}}
{{- end }}
