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

{{/* Matches dex-configmap.yaml's seeded staticPasswords admin entry exactly
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

{{/* Public origin the app is reached at. Defaults to charts/straiker-edge's
routed host/port; override if reached differently (own ingress, etc). */}}
{{- define "frontend.origin" -}}
{{- .Values.frontend.origin | default (printf "https://app.%s:%v" .Values.global.appDomain .Values.edgeHttpsPort) -}}
{{- end }}

{{/* ── dex (bundled local OIDC provider, builtin password-DB) ─────────────
Proxied through the frontend app itself (/dex/*) rather than published on its
own host. */}}

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

{{/* Bare host:port for Dex's internal Service. */}}
{{- define "dex.internalAddr" -}}
{{- printf "dex-service.%s.svc.cluster.local:%v" (include "dex.namespace" .) .Values.dex.service.port -}}
{{- end }}

{{/* Internal base URL for server-to-server calls (token/jwks exchange). */}}
{{- define "dex.internalUrl" -}}
{{- printf "http://%s" (include "dex.internalAddr" .) -}}
{{- end }}

{{/* Dex's gRPC connector-management/password-DB API — internal only. */}}
{{- define "dex.internalGrpcAddr" -}}
{{- printf "dex-service.%s.svc.cluster.local:5557" (include "dex.namespace" .) -}}
{{- end }}

{{/* ── frontend OIDC — falls back to the bundled dex stack; override all of
them together to point at a customer's own external IdP instead. */}}

{{- define "frontend.oidcIssuer" -}}
{{- .Values.frontend.oidc.issuer | default (printf "%s/dex" (include "frontend.origin" .)) -}}
{{- end }}

{{- define "frontend.oidcClientId" -}}
{{- .Values.frontend.oidc.clientId | default .Values.dex.staticClient.id -}}
{{- end }}

{{- define "frontend.oidcClientSecret" -}}
{{- .Values.frontend.oidc.clientSecret | default .Values.dex.staticClient.secret -}}
{{- end }}

{{- define "frontend.oidcAuthorizationEndpoint" -}}
{{- .Values.frontend.oidc.authorizationEndpoint | default (printf "%s/dex/auth" (include "frontend.origin" .)) -}}
{{- end }}

{{- define "frontend.oidcTokenEndpoint" -}}
{{- .Values.frontend.oidc.tokenEndpoint | default (printf "%s/dex/token" (include "dex.internalUrl" .)) -}}
{{- end }}

{{- define "frontend.oidcJwksUri" -}}
{{- .Values.frontend.oidc.jwksUri | default (printf "%s/dex/keys" (include "dex.internalUrl" .)) -}}
{{- end }}

