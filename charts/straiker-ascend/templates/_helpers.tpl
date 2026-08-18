{{- define "ascend.secretName" -}}straiker-secrets{{- end }}

{{- define "ascend.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{/*
Bifrost LLM gateway. Empty .Values.bifrost.baseUrl (default) resolves to
charts/straiker-core/charts/straiker-bifrost's own in-cluster Service --
override to route through a different Bifrost instead (e.g. a Straiker-
hosted virtual-key gateway), see values.yaml's own comment.
*/}}
{{- define "ascend.bifrostUrl" -}}
{{- .Values.bifrost.baseUrl | default (printf "http://straiker-bifrost-service.%s.svc.cluster.local:8090/v1" (include "ascend.namespace" .)) -}}
{{- end }}

{{/*
Env vars common to every ascend component.
*/}}
{{- define "ascend.commonEnv" -}}
- name: SYS__ENV
  value: "production"
- name: SYS__SELF_HOSTED
  value: "true"
- name: SYS__IRIS_VERSION
  value: {{ .Values.image.tag | quote }}
- name: SYS__SECRET_MANAGER_ENABLED
  value: "false"
- name: SYS__REDIS_URL
  value: {{ include "ascend.redisUrl" . | quote }}
- name: SYS__APPSYNC_ENABLED
  value: "false"
- name: SYS__ARCHIVE_ENABLED
  value: {{ .Values.archive.enabled | quote }}
{{- if .Values.archive.enabled }}
- name: SYS__ARCHIVE_TRANSPORT
  value: "redpanda_connect"
- name: SYS__ARCHIVE_GATEWAY_URL
  value: {{ include "ascend.archiveEndpoint" . | quote }}
- name: SYS__ARCHIVE_STREAM
  value: {{ .Values.archive.stream | quote }}
{{- end }}
- name: SYS__TARGET_URL_VALIDATION
  value: "false"
- name: SYS__REMOTE_CONTROLS_ENABLED
  value: "false"
- name: SYS__UNALIGNED_LLM_ENDPOINT
  value: {{ include "ascend.unalignedLLMEndpoint" . | quote }}
- name: SYS__UNALIGNED_LLM_THROTTLE_ENABLED
  value: {{ .Values.unalignedLLM.throttle.enabled | quote }}
- name: SYS__UNALIGNED_LLM_RPM
  value: {{ .Values.unalignedLLM.throttle.rpm | quote }}
- name: SYS__LOGGING_LEVEL
  value: {{ .Values.logging.level | quote }}
- name: SYS__BIFROST_BASE_URL
  value: {{ include "ascend.bifrostUrl" . | quote }}
# Only load-bearing when bifrost.baseUrl above points at a real virtual-key-
# enforcing Bifrost (e.g. Straiker-hosted) -- the default in-cluster Bifrost
# doesn't check this at all. Unset falls back to iris's own code default
# (settings.py's bifrost_api_key Field), harmless either way.
- name: SYS__BIFROST_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ascend.secretName" . }}
      key: BIFROST_API_KEY
      optional: true
- name: SYS__USE_SAQ_WORKERS
  value: "true"
- name: SYS__RATE_LIMIT_CHECK
  value: {{ .Values.rateLimitCheck | quote }}
{{- end }}

{{- define "ascend.image" -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{- define "ascend.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-ascend
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "ascend.controlPlaneUrl" -}}
{{- printf "http://straiker-ascend-control-plane.%s.svc.cluster.local" (include "ascend.namespace" .) -}}
{{- end }}

{{/*
Thin-client bridge endpoint — probes for apiType=thin apps are routed through
probe-shadow's own in-cluster Service (see templates/probe-shadow.yaml),
matching iris/deploy/local/docker-compose.yml's own SYS__IRIS_PRIVATELINK_ENDPOINT
wiring (http://probe-shadow:8005/chat there; here, probe-shadow's Service port
80 -> targetPort 8005, so plain port 80 on the Service name).
*/}}
{{- define "ascend.privatelinkEndpoint" -}}
{{- printf "http://straiker-ascend-probe-shadow.%s.svc.cluster.local/chat" (include "ascend.namespace" .) -}}
{{- end }}

{{/*
Redis — reuses charts/straiker-system's own instance (service "valkey", a
Redis-protocol-compatible fork) in this same namespace, rather than
deploying a second one.
*/}}
{{- define "ascend.redisUrl" -}}
{{- if .Values.redis.url -}}
{{- .Values.redis.url -}}
{{- else -}}
{{- printf "redis://valkey.%s.svc.cluster.local:6379" (include "ascend.namespace" .) -}}
{{- end -}}
{{- end }}

{{/*
Foundation (tenant/app/settings control plane) — straiker-frontend serves
this. Matches charts/straiker-defend's own foundationEndpoint helper.
*/}}
{{- define "ascend.foundationEndpoint" -}}
{{- if .Values.foundationEndpoint -}}
{{- .Values.foundationEndpoint -}}
{{- else -}}
{{- printf "http://straiker-frontend-service.%s.svc.cluster.local" (include "ascend.namespace" .) -}}
{{- end -}}
{{- end }}

{{/*
This chart's own externally-reachable URL, once an "ascend" route is added to
charts/straiker-edge's routes list (subdomain: ascend -> straiker-ascend-
control-plane:80) -- used as SYS__DATA_EXFILTRATION_ENDPOINT's default, the
capture-callback target for the DataPoint/data-exfiltration probe technique,
which needs iris's own control-plane reachable from outside its own pod.
Matches charts/straiker-core/charts/straiker-frontend's own "frontend.origin"
helper computation exactly (same global.appDomain/edgeHttpsPort convention).
*/}}
{{- define "ascend.externalUrl" -}}
{{- .Values.dataExfiltrationEndpoint | default (printf "https://ascend.%s:%v" .Values.global.appDomain .Values.edgeHttpsPort) -}}
{{- end }}

{{/*
straiker-frontend's own externally-routed origin -- the right CORS default
for control-plane's browser-facing API, since that's where a customer's
browser actually calls control-plane FROM. Same computation as charts/
straiker-core/charts/straiker-frontend's own "frontend.origin" helper (can't
read that chart's values directly -- independent top-level charts).
*/}}
{{- define "ascend.frontendOrigin" -}}
{{- .Values.corsAllowOrigins | default (printf "https://app.%s:%v" .Values.global.appDomain .Values.edgeHttpsPort) -}}
{{- end }}

{{/*
Argus detection endpoint — charts/straiker-defend's Service, in this same
namespace. install-straiker.sh installs straiker-defend unconditionally now
(regardless of product selection), since iris depends on it directly.
*/}}
{{- define "ascend.argusEndpoint" -}}
{{- if .Values.argus.endpoint -}}
{{- .Values.argus.endpoint -}}
{{- else -}}
{{- printf "http://straiker-defend.%s.svc.cluster.local/api/v1/detect" (include "ascend.namespace" .) -}}
{{- end -}}
{{- end }}

{{/*
Archive gateway — the shared straiker-system Redpanda Connect (Benthos),
same as charts/straiker-defend's own archiveEndpoint helper.
*/}}
{{- define "ascend.archiveEndpoint" -}}
{{- if .Values.archive.endpoint -}}
{{- .Values.archive.endpoint -}}
{{- else -}}
{{- printf "http://straiker-benthos.%s.svc.cluster.local:4195/archive" (include "ascend.namespace" .) -}}
{{- end -}}
{{- end }}

{{/*
Unaligned LLM endpoint — always straiker-inference's thanos release
(modelProfile=thanos, Mistral Nemo 12B). "inference-thanos", not the old
chart's bare "thanos" guess -- matches charts/straiker-inference's actual
per-model release/Service naming exactly (see charts/straiker-defend's own
llmEndpoints wiring for the same convention).
*/}}
{{- define "ascend.unalignedLLMEndpoint" -}}
{{- printf "http://inference-thanos.%s.svc.cluster.local:8000/v1/chat/completions" (include "ascend.namespace" .) -}}
{{- end }}

{{/*
Secret name/key holding the DB password. Defaults to straiker-secrets /
POSTGRES_PASSWORD_IRIS (charts/straiker-system's postgres.yaml Secret,
matching its "iris" database entry) unless overridden.
*/}}
{{- define "ascend.dbPasswordSecretName" -}}
{{- .Values.db.passwordSecret.name | default "postgres-secret" -}}
{{- end }}

{{- define "ascend.dbPasswordSecretKey" -}}
{{- .Values.db.passwordSecret.key | default "POSTGRES_PASSWORD_IRIS" -}}
{{- end }}

{{/*
Dedicated NodePool (charts/straiker-system's karpenter.iris — arm64-only,
tainted purpose=straiker-iris), unlike charts/straiker-defend which uses the
shared general-purpose pool. Merges any user-supplied nodeSelector on top.
*/}}
{{- define "ascend.nodeSelector" -}}
{{- $ns := deepCopy .Values.nodeSelector }}
{{- $_ := set $ns "purpose" "straiker-iris" }}
nodeSelector:
  {{- toYaml $ns | nindent 2 }}
{{- end }}
