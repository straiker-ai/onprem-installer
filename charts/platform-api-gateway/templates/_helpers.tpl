{{/*
Expand the name of the chart.
*/}}
{{- define "straiker.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "straiker.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
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

{{/*
Create the name of the service account to use
*/}}
{{- define "straiker.serviceAccountName" -}}
{{- printf "%s-service-account" .Release.Name }}
{{- end }}

{{/*
Escape double quotes in a string
*/}}
{{- define "straiker.escapeDoubleQuotes" -}}
  {{- regexReplaceAll "\"" . "\"" -}}
{{- end -}}

{{/*
Resolve namespace for a service.
If singleNamespace is true, returns Release.Namespace; otherwise returns the provided namespace.
Usage: {{ include "straiker.resolveNamespace" (dict "root" . "ns" "backend") }}
*/}}
{{- define "straiker.resolveNamespace" -}}
{{- if .root.Values.straiker.apiGateway.singleNamespace -}}
{{- .root.Release.Namespace -}}
{{- else -}}
{{- .ns -}}
{{- end -}}
{{- end -}}