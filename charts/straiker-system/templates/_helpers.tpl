{{- define "base.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
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

{{/*
Render a fully-qualified image ref from a {registry, repository, tag} map.
.image.repository must be relative (no registry host); .Values.global.dockerRegistry,
when set, overrides .image.registry so every component can point at one mirror.
Usage: {{ include "infra.image" (dict "image" $someImage "global" .Values.global) }}
*/}}
{{- define "infra.image" -}}
{{- $registry := .global.dockerRegistry | default .image.registry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") .image.repository .image.tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository .image.tag -}}
{{- end -}}
{{- end }}

{{- define "infra.redisImage" -}}
{{ include "infra.image" (dict "image" .Values.redis.image "global" .Values.global) }}
{{- end }}

{{/* Mirrored via charts/straiker-artifact's imageMirror.images (destRepository redpandadata/connect) — resolves through global.dockerRegistry like the other mirrored third-party images (redis/opensearch). */}}
{{- define "infra.benthosImage" -}}
{{ include "infra.image" (dict "image" .Values.benthos.image "global" .Values.global) }}
{{- end }}

{{- define "infra.opensearchUrl" -}}
{{- printf "http://opensearch-cluster-master.%s.svc.cluster.local:9200" (include "infra.namespace" .) -}}
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
