{{/* ── Bifrost ────────────────────────────────────────────────────────── */}}

{{- define "bifrost.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "bifrost.image" -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{/* Falls back to the parent chart's global.sharedNodeSelector — see
values.yaml's nodeSelector field. */}}
{{- define "bifrost.nodeSelector" -}}
{{- .Values.nodeSelector | default .Values.global.sharedNodeSelector | toYaml -}}
{{- end }}

{{- define "bifrost.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: bifrost
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
