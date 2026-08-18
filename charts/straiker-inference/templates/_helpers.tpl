{{/* Fixed secret name — customers must create this before installing (see
templates/secrets.yaml for the exact kubectl command). */}}
{{- define "straiker-inference.secretName" -}}straiker-secrets{{- end }}

{{- define "straiker-inference.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{/* vLLM image — Straiker's own build, mirrored by charts/straiker-artifact
under onprem-base/straiker/vllm (same /straiker/ prefix as frontend). */}}
{{- define "straiker-inference.image" -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{/*
Image for the model-pull init container's cloud-storage sync — a small
official CLI image, picked by cloud provider (no combined aws+gsutil image
exists). On EKS, prefer the mirrored image in global.dockerRegistry when set;
fall back to public ECR otherwise.
*/}}
{{- define "straiker-inference.modelSyncImage" -}}
{{- if eq .Values.cloudProvider "gke" -}}
gcr.io/google.com/cloudsdktool/cloud-sdk:531.0.0-slim
{{- else -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/aws-cli/aws-cli:2.24.24" ($registry | trimSuffix "/") -}}
{{- else -}}
public.ecr.aws/aws-cli/aws-cli:2.24.24
{{- end -}}
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

{{/* Karpenter NodePool name created by charts/straiker-system
(karpenter.gpu.nodePool.name) — used to auto-detect the GPU tier when
gpuProfile is left empty. */}}
{{- define "straiker-inference.gpuNodePool" -}}straiker-gpu{{- end }}

{{/*
Model profiles — Straiker-managed. Customers pick a name via modelProfile; do
not expose these fields (and note there's deliberately no "origin"/upstream
HF repo field here anymore — customers don't need to know what each product
tier is built on, and nothing in these templates ever consumed it anyway).
Each profile: storagePrefix, servedNames, defaultGpuProfile, gpuOverrides
(optional). storagePrefix is the FULL object-store path under
global.modelBucket/models/<storagePrefix>/ — set explicitly per model
(no shared version — the source GCS bucket doesn't tag every model's export
the same way, confirmed not unified across models), so update each one
independently when its underlying export changes rather than assuming they
move together. Must match charts/straiker-artifact's modelSync.models
destPath for whichever models are enabled, or the sync job populates a path
this chart never looks for.
*/}}
{{- define "straiker-inference.modelProfiles" -}}
antman:
  storagePrefix: antman
  servedNames: [antman]
  defaultGpuProfile: g4dn
hulk:
  storagePrefix: hulk
  servedNames: [hulk]
  defaultGpuProfile: g4dn
quicksilver:
  storagePrefix: quicksilver
  servedNames: [quicksilver]
  defaultGpuProfile: g4dn
  # quicksilver's architecture (InternLM2ForCausalLM) crashes vLLM v0.27.0's
  # CUDA graph capture with "forward() missing 1 required positional
  # argument: 'intermediate_tensors'" — a vLLM-upstream bug (InternLM2's
  # forward() has no default for that arg, and its warmup/capture path
  # apparently doesn't supply it for this model, unlike the other 6 models'
  # architectures which all worked fine). enforce_eager skips CUDA graph
  # capture entirely, sidestepping the crash — confirmed working end-to-end.
  # Costs some per-token latency vs. the graph-captured path; revisit once
  # upstream fixes this for InternLM2.
  enforceEager: true
thor:
  storagePrefix: thor
  servedNames: [thor]
  defaultGpuProfile: g4dn
vision:
  storagePrefix: vision
  servedNames: [vision]
  defaultGpuProfile: g4dn
  multimodal:
    limitImage: 1
    limitVideo: 0
wanda:
  storagePrefix: wanda
  servedNames: [wanda]
  defaultGpuProfile: g4dn
  multimodal:
    limitImage: 1
    limitVideo: 0
thanos:
  storagePrefix: thanos
  servedNames: [thanos]
  # g5 (24GB, bitsandbytes-quantized) is the default — the straiker/vllm
  # image already has vllm-bnb-plugin installed, so bitsandbytes works out of
  # the box despite moving out-of-tree upstream, and g5 is both cheaper than
  # g6e/p4d/a100 and (unlike g6e) an instance family most clusters already
  # have provisioned via charts/straiker-system's default
  # karpenter.gpu.instanceFamilies. g6e/p4d/a100 stay available below
  # (unquantized, more headroom) for customers who'd rather not rely on an
  # out-of-tree plugin or need more context length than the quantized tier
  # comfortably supports.
  defaultGpuProfile: g5
  gpuOverrides:
    g6e:  {dtype: bfloat16, max_model_len: "32768", mem_fraction_static: "0.90"}
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
  resources: &res16gb
    requests: {cpu: "2", memory: 8Gi}
    limits: {cpu: "4", memory: 12Gi}
g5:
  dtype: bfloat16
  max_model_len: "32768"
  mem_fraction_static: "0.9"
  nodeSelector:
    karpenter.k8s.aws/instance-family: g5
  resources: &res24gb
    requests: {cpu: "4", memory: 16Gi}
    limits: {cpu: "8", memory: 24Gi}
p4d:
  dtype: bfloat16
  max_model_len: "65536"
  mem_fraction_static: "0.9"
  nodeSelector:
    karpenter.k8s.aws/instance-family: p4d
  resources: &res40gb
    requests: {cpu: "8", memory: 32Gi}
    limits: {cpu: "16", memory: 48Gi}
g6e:
  # L40S, 48GB — verified against Straiker's own production thanos config
  # (g6e.4xlarge, plain bfloat16, no quantization needed).
  dtype: bfloat16
  max_model_len: "32768"
  mem_fraction_static: "0.9"
  nodeSelector:
    karpenter.k8s.aws/instance-family: g6e
  resources: *res40gb
p3:
  dtype: half
  max_model_len: "16384"
  mem_fraction_static: "0.9"
  max_num_seqs: "64"
  nodeSelector:
    karpenter.k8s.aws/instance-family: p3
  resources: *res16gb
t4:
  dtype: half
  max_model_len: "16384"
  mem_fraction_static: "0.9"
  max_num_seqs: "64"
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-tesla-t4
  resources: *res16gb
l4:
  dtype: bfloat16
  max_model_len: "32768"
  mem_fraction_static: "0.9"
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-l4
  resources: *res24gb
a100:
  dtype: bfloat16
  max_model_len: "65536"
  mem_fraction_static: "0.9"
  nodeSelector:
    cloud.google.com/gke-accelerator: nvidia-tesla-a100
  resources: *res40gb
{{- end }}

{{/* Prefixed rather than the bare model name — install-straiker.sh runs
`helm upgrade --install inference-<model> straiker/straiker-inference --set
modelProfile=<model>`, and every model shares one flat namespace (no
per-model namespacing), so "inference-<model>" avoids ambiguity in
`kubectl get all -n straiker` alongside straiker-core/straiker-system's own
resources, and matches Straiker's own production release naming
(inference-antman, inference-thanos, ...). */}}
{{- define "straiker-inference.fullname" -}}
{{- printf "inference-%s" .Values.modelProfile | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Applied to every container in this chart (main vllm process and both
init container variants). Deliberately does NOT set
runAsNonRoot/runAsUser or readOnlyRootFilesystem — we don't control whether
the straiker/vllm image's default user is non-root or what else it writes to
outside the already-mounted volumes, and guessing wrong there breaks pod
startup outright (CreateContainerConfigError) rather than just under-hardening.
These three are safe regardless: GPU access goes through the device plugin at
the container-runtime level, not Linux capabilities, so dropping them doesn't
affect nvidia.com/gpu scheduling or CUDA access. */}}
{{- define "straiker-inference.securityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "straiker-inference.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "straiker-inference.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
