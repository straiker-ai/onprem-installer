{{/* Fixed secret name — customers must create this before installing. */}}
{{- define "straiker-inference.secretName" -}}straiker-secrets{{- end }}

{{/* vLLM image tag — set in values.yaml; override per-release if needed. */}}
{{- define "straiker-inference.vllmTag" -}}{{ .Values.image.tag | default "v0.8.5.post1" }}{{- end }}

{{/*
Image for the model-pull init container's cloud-storage sync — a small
official CLI image, picked by cloud provider (no combined aws+gsutil image exists).
*/}}
{{- define "straiker-inference.modelSyncImage" -}}
{{- if eq .Values.cloudProvider "gke" -}}
gcr.io/google.com/cloudsdktool/cloud-sdk:531.0.0-slim
{{- else -}}
public.ecr.aws/aws-cli/aws-cli:2.24.24
{{- end -}}
{{- end }}

{{/*
Recursive sync command from a global.modelBucket subpath into a local dir.
Usage: {{ include "straiker-inference.modelSyncCmd" (dict "root" . "src" "models/foo" "dst" "/var/lib/models") }}
*/}}
{{- define "straiker-inference.modelSyncCmd" -}}
{{- $bucket := required "global.modelBucket is required" .root.Values.global.modelBucket -}}
{{- if eq .root.Values.cloudProvider "gke" -}}
gsutil -m rsync -r "{{ $bucket }}/{{ .src }}" "{{ .dst }}"
{{- else -}}
aws s3 sync --only-show-errors "{{ $bucket }}/{{ .src }}" "{{ .dst }}"
{{- end -}}
{{- end }}

{{/* Karpenter NodePool name created by straiker-base. */}}
{{- define "straiker-inference.gpuNodePool" -}}straiker-gpu{{- end }}

{{/*
Model profiles — Straiker-managed. Customers pick a name via modelProfile; do not expose these fields.
Each profile: origin, storagePrefix, servedNames, defaultGpuProfile, gpuOverrides (optional).
origin records the upstream Hugging Face provenance. storagePrefix is the internal object-store path
under global.modelBucket/models/<storagePrefix>/ and is the canonical delivery path into the inference pod.
*/}}
{{- define "straiker-inference.modelProfiles" -}}
antman:
  origin: straikerinc/Llama-3.2-3B-Instruct-argus-v23
  storagePrefix: antman
  servedNames: [antman, "straikerinc/Llama-3.2-3B-Instruct-argus-v23"]
  defaultGpuProfile: g4dn
hulk:
  origin: straikerinc/Qwen3-4B-Instruct-2507
  storagePrefix: hulk
  servedNames: [hulk, "straikerinc/Qwen3-4B-Instruct-2507"]
  defaultGpuProfile: g4dn
quicksilver:
  origin: straikerinc/internlm2_5-1_8b-chat-argus-v23
  storagePrefix: quicksilver
  servedNames: [quicksilver, "straikerinc/internlm2_5-1_8b-chat-argus-v23"]
  defaultGpuProfile: g4dn
thor:
  origin: straikerinc/Qwen2.5-3B-instruct-argus-v23
  storagePrefix: thor
  servedNames: [thor, "straikerinc/Qwen2.5-3B-instruct-argus-v23"]
  defaultGpuProfile: g4dn
thanos:
  origin: straikerinc/mistral-nemo-12b-uncensored
  storagePrefix: thanos
  servedNames: [thanos, "straikerinc/mistral-nemo-12B-uncensored"]
  defaultGpuProfile: g5
  gpuOverrides:
    g5:   {dtype: bfloat16, max_model_len: "16384", mem_fraction_static: "0.90", quantization: bitsandbytes}
    l4:   {dtype: bfloat16, max_model_len: "16384", mem_fraction_static: "0.90", quantization: bitsandbytes}
    p4d:  {dtype: bfloat16, max_model_len: "32768", mem_fraction_static: "0.95"}
    a100: {dtype: bfloat16, max_model_len: "32768", mem_fraction_static: "0.95"}
{{- end }}

{{/*
GPU profiles — Straiker-managed. dtype/max_model_len/mem_fraction_static/nodeSelector per GPU tier.
g4dn/t4/p3 (16 GB): half precision. g5/l4 (24 GB), p4d/a100 (40 GB): bfloat16.
*/}}
{{- define "straiker-inference.gpuProfiles" -}}
g4dn:
  dtype: half
  max_model_len: "16384"
  mem_fraction_static: "0.9"
  max_num_seqs: "64"
  nodeSelector:
    karpenter.k8s.aws/instance-family: g4dn
g5:
  dtype: bfloat16
  max_model_len: "32768"
  mem_fraction_static: "0.9"
  nodeSelector:
    karpenter.k8s.aws/instance-family: g5
p4d:
  dtype: bfloat16
  max_model_len: "65536"
  mem_fraction_static: "0.9"
  nodeSelector:
    karpenter.k8s.aws/instance-family: p4d
p3:
  dtype: half
  max_model_len: "16384"
  mem_fraction_static: "0.9"
  max_num_seqs: "64"
  nodeSelector:
    karpenter.k8s.aws/instance-family: p3
t4:
  dtype: half
  max_model_len: "16384"
  mem_fraction_static: "0.9"
  max_num_seqs: "64"
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-tesla-t4
l4:
  dtype: bfloat16
  max_model_len: "32768"
  mem_fraction_static: "0.9"
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-l4
a100:
  dtype: bfloat16
  max_model_len: "65536"
  mem_fraction_static: "0.9"
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-tesla-a100
{{- end }}

{{/*
Expand the name of the chart.
*/}}
{{- define "straiker-inference.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "straiker-inference.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if .Values.modelProfile }}
{{- .Values.modelProfile | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "straiker-inference.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "straiker-inference.labels" -}}
helm.sh/chart: {{ include "straiker-inference.chart" . }}
{{ include "straiker-inference.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "straiker-inference.selectorLabels" -}}
app.kubernetes.io/name: {{ include "straiker-inference.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
