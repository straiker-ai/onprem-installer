{{- define "artifact-sync.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "artifact-sync.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-artifact-sync
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
An image's sku is its source repo segment, not a separate field — a source of
".../onprem-base/foo" is sku "base", ".../onprem-pro/bar" is sku "pro". Assumes
the fixed "<host>/<project>/onprem-<sku>/<name>" layout (segment index 2).
Usage: {{ include "artifact-sync.imageSku" $img.source }}
*/}}
{{- define "artifact-sync.imageSku" -}}
{{- trimPrefix "onprem-" (index (splitList "/" .) 2) -}}
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
