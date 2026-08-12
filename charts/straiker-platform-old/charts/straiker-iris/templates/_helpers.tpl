{{- define "iris.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{/* Bifrost LLM gateway URL — auto-derives to the sibling bifrost-service unless overridden. */}}
{{- define "iris.bifrostUrl" -}}
{{- .Values.bifrost.serviceUrl | default (printf "http://bifrost-service.%s.svc.cluster.local:8090/v1" (include "iris.namespace" .)) }}
{{- end }}

{{- define "iris.secretName" -}}straiker-secrets{{- end }}

{{/* Iris image tag — set in values.yaml; override per-release if needed. */}}
{{- define "iris.imageTag" -}}{{ .Values.image.tag | default "v4.28.0" }}{{- end }}

{{/* Image used by the in-cluster Redis-compatible deployment. */}}
{{/* Valkey is the BSD-3-Clause Linux Foundation fork of Redis (drop-in compatible). */}}
{{- define "iris.redisImage" -}}
valkey/valkey:8-alpine
{{- end }}

{{/* Liquibase image used by the db-migrate Job. */}}
{{- define "iris.liquibaseImage" -}}
liquibase/liquibase:4.28
{{- end }}

{{/* Unaligned LLM endpoint — always thanos (Mistral 12B). */}}
{{- define "iris.unalignedLLMEndpoint" -}}http://thanos.{{ .Release.Namespace }}.svc.cluster.local:8000/v1/chat/completions{{- end }}

{{- define "iris.image" -}}
{{- $repo := .Values.image.repository }}
{{- if not $repo }}
  {{- $repo = printf "%s/docker/onprem-iris" (required "global.registry is required" .Values.global.registry) }}
{{- end }}
{{- printf "%s:%s" $repo (include "iris.imageTag" .) }}
{{- end }}

{{- define "iris.redisUrl" -}}
{{- if .Values.inClusterRedis.enabled }}
{{- printf "redis://iris-redis.%s.svc.cluster.local:6379" (include "iris.namespace" .) }}
{{- else }}
{{- required "iris.redis.url is required when inClusterRedis.enabled=false" .Values.iris.redis.url }}
{{- end }}
{{- end }}

{{/*
Secret name and key holding the DB password.
Defaults to straiker-secrets / SYS__ASCEND_RDS_PASSWORD unless overridden via
db.passwordSecret.name / db.passwordSecret.key (e.g. for in-cluster postgres).
*/}}
{{- define "iris.dbPasswordSecretName" -}}
{{- .Values.db.passwordSecret.name | default (include "iris.secretName" .) }}
{{- end }}

{{- define "iris.dbPasswordSecretKey" -}}
{{- .Values.db.passwordSecret.key | default "SYS__ASCEND_RDS_PASSWORD" }}
{{- end }}

{{- define "iris.nodeSelector" -}}
{{- $ns := deepCopy .Values.nodeSelector }}
{{- $arch := .Values.global.arch | default .Values.arch }}
{{- if $arch }}
  {{- $_ := set $ns "kubernetes.io/arch" $arch }}
{{- end }}
{{- if $ns }}
nodeSelector:
  {{- toYaml $ns | nindent 2 }}
{{- end }}
{{- end }}

{{- define "iris.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: iris
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Auto-derives to straiker-control service unless overridden. */}}
{{- define "iris.controlPlaneEndpoint" -}}
{{- .Values.straiker_control_plane_endpoint | default (printf "http://straiker-control-service.%s.svc.cluster.local" .Release.Namespace) }}
{{- end }}

{{/* Redpanda (Kafka) bootstrap servers for event archiving. */}}
{{- define "iris.kafkaBootstrapServers" -}}
{{- $infraNs := .Values.global.infraNamespace | default "straiker-infra" -}}
{{- .Values.iris.archive.bootstrapServers | default (printf "straiker-infra.%s.svc.cluster.local:9093" $infraNs) }}
{{- end }}

{{/*
Env vars common to all iris components.
*/}}
{{- define "iris.commonEnv" -}}
- name: SYS__ENV
  value: "production"
- name: SYS__SELF_HOSTED
  value: "true"
- name: SYS__IRIS_VERSION
  value: {{ include "iris.imageTag" . | quote }}
- name: SYS__SECRET_MANAGER_ENABLED
  value: "false"
- name: SYS__REDIS_URL
  value: {{ include "iris.redisUrl" . | quote }}
- name: SYS__APPSYNC_ENABLED
  value: "false"
- name: SYS__ARCHIVE_ENABLED
  value: "true"
- name: SYS__ARCHIVE_KAFKA_BOOTSTRAP_SERVERS
  value: {{ include "iris.kafkaBootstrapServers" . | quote }}
- name: SYS__ARCHIVE_STREAM
  value: {{ .Values.iris.archive.stream | default "iris-events" | quote }}
- name: SYS__TARGET_URL_VALIDATION
  value: "false"
- name: SYS__REMOTE_CONTROLS_ENABLED
  value: "false"
- name: SYS__UNALIGNED_LLM_ENDPOINT
  value: {{ include "iris.unalignedLLMEndpoint" . | quote }}
- name: SYS__UNALIGNED_LLM_THROTTLE_ENABLED
  value: {{ .Values.iris.unalignedLLM.throttle.enabled | quote }}
- name: SYS__UNALIGNED_LLM_RPM
  value: {{ .Values.iris.unalignedLLM.throttle.rpm | quote }}
- name: SYS__LOGGING_LEVEL
  value: {{ .Values.iris.logging.level | quote }}
- name: SYS__BIFROST_BASE_URL
  value: {{ include "iris.bifrostUrl" . | quote }}
- name: SYS__BIFROST_API_KEY
  value: "none"
- name: SYS__USE_SAQ_WORKERS
  value: "true"
- name: SYS__RATE_LIMIT_CHECK
  value: {{ .Values.rateLimitCheck | quote }}
{{- end }}
