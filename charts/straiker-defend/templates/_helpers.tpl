{{/* Fixed secret name — customers must create this before installing. */}}
{{- define "defend.secretName" -}}straiker-secrets{{- end }}

{{/* Chart-managed secret for the auto-generated session signing key. */}}
{{- define "defend.sessionSecretName" -}}straiker-defend-session-secret{{- end }}

{{- define "defend.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{/*
Resolve the argus image reference. global.dockerRegistry (relative
repository, no registry host) takes over when set — same convention as
every other chart in this repo.
*/}}
{{- define "defend.image" -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{/*
Image for the tokenizer-pull init container's cloud-storage sync — a small
official CLI image, picked by cloud provider (no combined aws+gsutil image
exists). Not mirrored through global.dockerRegistry since it's a third-party
image pulled directly from its own public registry.
*/}}
{{- define "defend.modelSyncImage" -}}
{{- if eq .Values.cloudProvider "gke" -}}
gcr.io/google.com/cloudsdktool/cloud-sdk:531.0.0-slim
{{- else -}}
public.ecr.aws/aws-cli/aws-cli:2.24.24
{{- end -}}
{{- end }}

{{/*
Recursive sync command from a global.modelBucket subpath into a local dir.
Usage: {{ include "defend.modelSyncCmd" (dict "root" . "src" "tokenizer/foo" "dst" "/tmp/tok") }}
*/}}
{{- define "defend.modelSyncCmd" -}}
{{- $bucket := required "global.modelBucket is required" .root.Values.global.modelBucket -}}
{{- if eq .root.Values.cloudProvider "gke" -}}
gsutil -m rsync -r "{{ $bucket }}/{{ .src }}" "{{ .dst }}"
{{- else -}}
aws s3 sync --only-show-errors "{{ $bucket }}/{{ .src }}" "{{ .dst }}"
{{- end -}}
{{- end }}

{{/*
Redis — reuses charts/straiker-system's own instance (service "valkey", a
Redis-protocol-compatible fork) in this same namespace, rather than
deploying a second one.
*/}}
{{- define "defend.redisUrl" -}}
{{- if .Values.redis.url -}}
{{- .Values.redis.url -}}
{{- else -}}
{{- printf "redis://valkey.%s.svc.cluster.local:6379" (include "defend.namespace" .) -}}
{{- end -}}
{{- end }}

{{/*
Foundation (tenant/app/settings control plane) — straiker-frontend serves
this role in this repo's architecture. Auto-derives to that service in this
same namespace.
*/}}
{{- define "defend.foundationEndpoint" -}}
{{- if .Values.foundation.endpoint -}}
{{- .Values.foundation.endpoint -}}
{{- else -}}
{{- printf "http://straiker-frontend-service.%s.svc.cluster.local" (include "defend.namespace" .) -}}
{{- end -}}
{{- end }}

{{/*
Archive endpoint — charts/straiker-system's single shared Redpanda Connect
(Benthos) instance, in this same namespace.
*/}}
{{- define "defend.archiveEndpoint" -}}
{{- if .Values.archive.endpoint -}}
{{- .Values.archive.endpoint -}}
{{- else -}}
{{- printf "http://straiker-benthos.%s.svc.cluster.local:4195/archive" (include "defend.namespace" .) -}}
{{- end -}}
{{- end }}

{{/*
NodeSelector — merges Values.nodeSelector with charts/straiker-system's
shared, untainted NodePool label. No dedicated "straiker-argus" NodePool:
this chart runs alongside opensearch/postgres/redis on the same shared
capacity rather than provisioning its own Karpenter pool + taint, matching
this installer's single-namespace, keep-it-simple design over
straiker-platform-old's per-service node-pool isolation.
*/}}
{{- define "defend.nodeSelector" -}}
{{- $ns := deepCopy .Values.nodeSelector }}
{{- if .Values.karpenter.enabled }}
  {{- $_ := set $ns "purpose" "general" }}
{{- end }}
{{- if $ns }}
nodeSelector:
  {{- toYaml $ns | nindent 2 }}
{{- end }}
{{- end }}

{{- define "defend.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-defend
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
