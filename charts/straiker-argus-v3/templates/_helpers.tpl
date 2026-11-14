{{/*
Shared fragments.

No `metadata.namespace` anywhere in this chart, deliberately. The v1 chart hard-
codes `namespace: argus` in every template, which means `helm -n <other>` still
renders v1's namespace and collides with the live v1 release. Omitting the field
lets `--namespace` decide, so the same chart can serve a canary namespace, a
per-developer namespace, or the eventual cutover to `argus` with no edit.
*/}}

{{/*
The configuration every pod in this chart needs: which environment it is, where
its secrets are, and where its shared state lives.

The daemons need this and little else; the API pod needs this plus egress. Kept
as one fragment so the three cannot drift into disagreeing about the same Redis.
*/}}
{{- /*
  The three annotations Grafana Alloy discovers metrics on, shared by all three
  workloads. Read out of `grafana-k8s-monitoring-alloy-metrics` rather than guessed:
  the gate is `k8s.grafana.com/scrape` (NOT `metrics.scrape`, which exists but gates
  nothing), the path comes from `metrics.path`, and `metrics.portNumber` overrides the
  target address -- which is what lets this work on a port no Service exposes.

  Alloy discovers pods cluster-wide, scrapes every 1m with a 10s timeout, and derives
  the `job` label from the `app` pod label when `k8s.grafana.com/job` is unset. Each
  workload already carries a distinct `app`, so the three appear as three jobs, which
  is right -- an API pod and a compactor are not the same thing.

  ⚠️ **Deliberately not added to any Service.** The metrics port is reachable only at
  the pod IP, which is where Alloy connects. Putting it in the Service would expose
  operational internals on the same surface the api-gateway routes tenant traffic to.
*/ -}}
{{- define "argus-v3.metricsAnnotations" -}}
k8s.grafana.com/scrape: "true"
k8s.grafana.com/metrics.path: "/metrics"
k8s.grafana.com/metrics.portNumber: "{{ .Values.argus.metrics.port }}"
{{- end -}}

{{- define "argus-v3.baseEnv" -}}
{{- /*
  SYS__ENV, not SYS__ARGUS_ENV. The v1 chart sets the latter on every pod, and
  the v3 settings field is `env` -- so the old name is an unknown variable that
  parses and is discarded, and the pod comes up believing it is running locally.

  Which is also why the value needs checking here. `SYS__ARGUS_ENV` was never read,
  so the v1 charts could carry `stage` and `prod` indefinitely without either being
  a legal DeploymentEnv value. Making the variable real made those values fatal:
  Settings validates the enum at import, so a wrong spelling is not a degraded pod,
  it is a CrashLoopBackOff across the namespace with the reason six frames into a
  pydantic traceback. It cost exactly that on stage.

  Rendered rather than deployed is the cheapest place to catch it: the pipeline
  templates all four overlays before it builds anything, so this fails in seconds
  instead of at the end of a ten minute --atomic timeout.
*/ -}}
{{- $envs := list "local" "dev" "staging" "production" -}}
{{- if not (has .Values.env $envs) -}}
{{- fail (printf "env is %q, which is not a DeploymentEnv value (%s). SYS__ENV is validated at import, so every pod would CrashLoop -- note it is `staging` and `production`, not the `stage` and `prod` the v1 charts use." .Values.env (join "|" $envs)) -}}
{{- end -}}
- name: SYS__ENV
  value: {{ .Values.env | quote }}
- name: SYS__SECRET_MANAGER_ENABLED
  value: "true"
- name: SYS__SECRET_MANAGER_REGION
  value: {{ .Values.argus.secretManager.region | quote }}
- name: SYS__SECRET_MANAGER_SECRET_NAME
  value: {{ .Values.argus.secretManager.secretName | quote }}
- name: SYS__REDIS_URL
  value: {{ .Values.argus.redis.url | quote }}
# Logging, here rather than in deployment.yaml so both daemons get it too: a
# compactor emitting console text while the API emits JSON is the same
# two-parsers-for-one-stream problem, inside one release.
#
# Both set explicitly, neither relying on the field default. The defaults are
# chosen for a laptop, and the previous logging layer shipped for months emitting
# exactly those in production because nothing read the setting at all.
- name: SYS__LOGGING__RENDERER
  value: "json"
- name: SYS__LOGGING__LEVEL
  value: {{ (.Values.argus.logging).level | default "INFO" | quote }}
{{- end -}}

{{- /*
  Tenant config and the transcript role, for every pod that touches it: the
  agent-config daemon consumes the topic, and the compactor and the API pods (for
  attachments) write under the keys it delivers.

  ENABLED is one value for all three, and true only where the consumer actually
  renders. Writers hold every write until the consumer has synced, so a writer
  told "on" with no consumer behind it would stop transcripts for every tenant.
*/ -}}
{{- define "argus-v3.transcriptKeysEnv" -}}
{{- $cfg := .Values.argus.agentConfig -}}
- name: SYS__TENANT_CONFIG__ENABLED
  value: "{{ if and .Values.argus.tenantConfig.enabled $cfg.enabled $cfg.bootstrapServers }}true{{ else }}false{{ end }}"
- name: SYS__TENANT_CONFIG__TOPIC
  value: {{ .Values.argus.tenantConfig.topic | quote }}
- name: SYS__COMPACTOR__TRANSCRIPT_ROLE_ARN
  value: {{ .Values.argus.compactor.transcriptRoleArn | default "" | quote }}
{{- end -}}

{{/*
Where pods in this chart are allowed to run. Same dedicated nodes as v1: the
taint is what keeps general workloads off them, and the selector is what keeps
these pods on them.
*/}}
{{- define "argus-v3.placement" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
A daemon's topology spread and PDB (values `daemons`, off by default). Called with
(dict "root" $ "app" "<the Deployment's app label>").
*/}}
{{- define "argus-v3.daemonSpread" -}}
{{- with .root.Values.daemons.topologySpread }}
{{- if .enabled }}
topologySpreadConstraints:
- maxSkew: {{ .maxSkew }}
  {{- with .minDomains }}
  minDomains: {{ . }}
  {{- end }}
  topologyKey: {{ .topologyKey }}
  whenUnsatisfiable: {{ .whenUnsatisfiable }}
  labelSelector:
    matchLabels:
      app: {{ $.app }}
  {{- with .matchLabelKeys }}
  matchLabelKeys:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
{{- end -}}
{{- define "argus-v3.daemonPdb" -}}
{{- with .root.Values.daemons.pdb }}
{{- if .enabled }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $.app }}-pdb
  labels:
    app.kubernetes.io/part-of: argus-v3
spec:
  maxUnavailable: {{ .maxUnavailable }}
  selector:
    matchLabels:
      app: {{ $.app }}
{{- end }}
{{- end }}
{{- end -}}
