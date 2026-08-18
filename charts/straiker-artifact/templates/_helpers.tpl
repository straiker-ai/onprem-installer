{{- define "artifact-sync.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "artifact-sync.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-artifact-sync
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
An image's sku is its source repo segment, not a separate field — a source of
".../onprem-base/foo" is sku "base", ".../onprem-pro/bar" is sku "pro". Assumes
the fixed "<host>/onprem-<sku>/<name>" layout (segment index 1).
Usage: {{ include "artifact-sync.imageSku" $img.source }}
*/}}
{{- define "artifact-sync.imageSku" -}}
{{- trimPrefix "onprem-" (index (splitList "/" .) 1) -}}
{{- end }}

{{/*
Image for the mirror Job's main container — needs a CLI that can mint
destination-registry credentials (aws ecr get-login-password on eks, gcloud
auth print-access-token on gke); crane itself comes from a separate
initContainer either way. Same pattern as straiker-inference/defend's
modelSyncImage, just for the mirror Job's tool image instead of the
model-sync one.
*/}}
{{- define "artifact-sync.mirrorToolImage" -}}
{{- if eq .Values.cloudProvider "gke" -}}
gcr.io/google.com/cloudsdktool/cloud-sdk:531.0.0-slim
{{- else -}}
public.ecr.aws/aws-cli/aws-cli:2.17.62
{{- end -}}
{{- end }}

{{/*
This chart's Jobs must schedule and complete before charts/straiker-system runs
— which means before its Karpenter NodePools exist. The only nodes available
that early are terraform/aws/eks's "system" managed node group, tainted
CriticalAddonsOnly=true:NoSchedule to reserve it for Karpenter + core addons —
so these Jobs need an explicit toleration for it. Harmless no-op on a
bring-your-own-cluster that doesn't use this taint at all.
*/}}
{{- define "artifact-sync.tolerations" -}}
tolerations:
  - key: CriticalAddonsOnly
    operator: Equal
    value: "true"
    effect: NoSchedule
{{- end }}
