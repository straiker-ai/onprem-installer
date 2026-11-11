{{/*
Expand the name of the chart.
*/}}
{{- define "straiker.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "straiker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "straiker.labels" -}}
helm.sh/chart: {{ include "straiker.chart" . }}
{{ include "straiker.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "straiker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "straiker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
