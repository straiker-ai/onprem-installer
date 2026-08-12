{{/* Fixed secret name — customers must create this before installing. */}}
{{- define "argus.secretName" -}}straiker-secrets{{- end }}

{{/* Chart-managed secret for auto-generated session key. */}}
{{- define "argus.sessionSecretName" -}}straiker-session-secret{{- end }}

{{- define "argus.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{/* Argus image tag — set in values.yaml; override per-release if needed. */}}
{{- define "argus.imageTag" -}}{{ .Values.image.tag | default "v0.1.15" }}{{- end }}

{{/* Image used by the in-cluster Redis-compatible deployment. */}}
{{/* Valkey is the BSD-3-Clause Linux Foundation fork of Redis (drop-in compatible). */}}
{{- define "argus.redisImage" -}}
valkey/valkey:8-alpine
{{- end }}

{{/*
Image for the tokenizer-pull init container's cloud-storage sync — a small
official CLI image, picked by cloud provider (no combined aws+gsutil image exists).
*/}}
{{- define "argus.modelSyncImage" -}}
{{- if eq .Values.cloudProvider "gke" -}}
gcr.io/google.com/cloudsdktool/cloud-sdk:531.0.0-slim
{{- else -}}
public.ecr.aws/aws-cli/aws-cli:2.24.24
{{- end -}}
{{- end }}

{{/*
Recursive sync command from a global.modelBucket subpath into a local dir.
Usage: {{ include "argus.modelSyncCmd" (dict "root" . "src" "tokenizers/foo" "dst" "/tmp/tok") }}
*/}}
{{- define "argus.modelSyncCmd" -}}
{{- $bucket := required "global.modelBucket is required" .root.Values.global.modelBucket -}}
{{- if eq .root.Values.cloudProvider "gke" -}}
gsutil -m rsync -r "{{ $bucket }}/{{ .src }}" "{{ .dst }}"
{{- else -}}
aws s3 sync --only-show-errors "{{ $bucket }}/{{ .src }}" "{{ .dst }}"
{{- end -}}
{{- end }}

{{/* Karpenter NodePool name created by straiker-base. */}}
{{- define "argus.gpuNodePool" -}}straiker-argus{{- end }}


{{/*
Cluster name from ops chart convention — pulled from node discovery tag.
*/}}
{{- define "argus.clusterName" -}}
{{ .Values.clusterName | default "" }}
{{- end }}

{{/*
Resolve an image reference. When image.repository is set explicitly, use it as-is.
*/}}
{{- define "argus.image" -}}
{{- $repo := .Values.image.repository }}
{{- if not $repo }}
  {{- $repo = printf "%s/docker/onprem-argus" (required "global.registry is required" .Values.global.registry) }}
{{- end }}
{{- printf "%s:%s" $repo (include "argus.imageTag" .) }}
{{- end }}

{{/*
NodeSelector — merges Values.nodeSelector with arch and optional Karpenter labels.
global.arch takes precedence over Values.arch.
*/}}
{{- define "argus.nodeSelector" -}}
{{- $ns := deepCopy .Values.nodeSelector }}
{{- $arch := .Values.global.arch | default .Values.arch }}
{{- if $arch }}
  {{- $_ := set $ns "kubernetes.io/arch" $arch }}
{{- end }}
{{- if .Values.karpenter.enabled }}
  {{- $_ := set $ns "purpose" "straiker-argus" }}
  {{- $_ := set $ns "karpenter.sh/nodepool" (include "argus.gpuNodePool" .) }}
{{- end }}
nodeSelector:
  {{- toYaml $ns | nindent 2 }}
{{- end }}

{{/*
Redpanda bootstrap servers.
Auto-derives to the in-cluster Redpanda service in the infra namespace.
*/}}
{{- define "argus.redpandaBootstrapServers" -}}
{{- $infraNs := .Values.global.infraNamespace | default "straiker-infra" -}}
{{- printf "straiker-infra.%s.svc.cluster.local:9093" $infraNs -}}
{{- end }}

{{/*
Foundation (straiker-control) endpoint.
Auto-derives to the in-cluster straiker-control service if not overridden.
*/}}
{{- define "argus.foundationEndpoint" -}}
{{- if .Values.argus.foundation.endpoint -}}
{{- .Values.argus.foundation.endpoint -}}
{{- else -}}
http://straiker-control-service.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "argus.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: argus
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
