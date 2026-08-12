{{- define "bifrost.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "bifrost.image" -}}
{{- $repo := .Values.image.repository }}
{{- if not $repo }}
  {{- $repo = printf "%s/docker/platform/bifrost" (required "global.registry is required" .Values.global.registry) }}
{{- end }}
{{- printf "%s:%s" $repo .Values.image.tag }}
{{- end }}

{{- define "bifrost.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: bifrost
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Redis address for the bifrost config — host:port without scheme. */}}
{{- define "bifrost.redisAddress" -}}
{{- .Values.redis.address | default (printf "iris-redis.%s.svc.cluster.local:6379" (include "bifrost.namespace" .)) }}
{{- end }}

{{/* In-cluster service URL — used by iris workers for SYS__BIFROST_BASE_URL. */}}
{{- define "bifrost.serviceUrl" -}}
{{- printf "http://bifrost-service.%s.svc.cluster.local:%d/v1" (include "bifrost.namespace" .) (.Values.service.port | int) }}
{{- end }}

{{- define "bifrost.nodeSelector" -}}
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
