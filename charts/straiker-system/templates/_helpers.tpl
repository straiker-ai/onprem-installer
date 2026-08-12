{{- define "base.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- if and (or .Values.karpenter.gpu .Values.karpenter.argus .Values.karpenter.iris) (eq .Values.cloudProvider "eks") -}}
  {{- $name := .Values.clusterName | default "" -}}
  {{- if not $name -}}
    {{- fail "clusterName is required when using Karpenter on EKS" -}}
  {{- end -}}
{{- end }}
{{- define "base.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "base.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "base.clusterName" -}}
{{- $name := .Values.clusterName | default "" -}}
{{- if not $name -}}
  {{- fail "clusterName is required for EKS Karpenter node discovery" -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{- define "infra.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "infra.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-system
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "infra.redisImage" -}}
{{ .Values.redis.image.repository }}:{{ .Values.redis.image.tag }}
{{- end }}

{{- define "infra.karpenterNodePool" -}}
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: {{ .pool.name }}
  labels:
    {{- include "base.labels" .root | nindent 4 }}
spec:
  template:
    metadata:
      labels:
        {{- range $k, $v := .pool.labels }}
        {{ $k }}: {{ $v | quote }}
        {{- end }}
    spec:
      {{- with .pool.taints }}
      taints:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      nodeClassRef:
        group: {{ .nodeClassGroup }}
        kind: {{ .nodeClassKind }}
        name: {{ .nodeClassName }}
      requirements:
        {{- toYaml .pool.requirements | nindent 8 }}
        {{- toYaml .extraRequirements | nindent 8 }}
      expireAfter: {{ .pool.expireAfter }}
  disruption:
    consolidationPolicy: {{ .pool.disruption.consolidationPolicy }}
    consolidateAfter: {{ .pool.disruption.consolidateAfter }}
  limits:
    {{- toYaml .pool.limits | nindent 4 }}
{{- end }}
