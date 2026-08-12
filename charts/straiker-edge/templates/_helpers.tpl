{{- define "edge.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "edge.image" -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{- define "edge.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-edge
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "edge.nodeSelector" -}}
{{- .Values.nodeSelector | default .Values.global.sharedNodeSelector | toYaml -}}
{{- end }}
