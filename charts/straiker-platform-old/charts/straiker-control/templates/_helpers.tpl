{{- define "cp.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "cp.secretName" -}}straiker-secrets{{- end }}

{{- define "cp.authSecretName" -}}straiker-control-auth{{- end }}

{{- define "cp.imageTag" -}}{{ .Values.image.tag | default "v2026.4.5" }}{{- end }}

{{- define "cp.migrateImage" -}}
{{- $repo := .Values.dbMigrate.image.repository }}
{{- if not $repo }}
  {{- $repo = printf "%s/docker/onprem-frontend-migrate" (required "global.registry is required" .Values.global.registry) }}
{{- end }}
{{- printf "%s:%s" $repo (include "cp.imageTag" .) }}
{{- end }}

{{- define "cp.image" -}}
{{- $repo := .Values.image.repository }}
{{- if not $repo }}
  {{- $repo = printf "%s/docker/onprem-frontend" (required "global.registry is required" .Values.global.registry) }}
{{- end }}
{{- printf "%s:%s" $repo (include "cp.imageTag" .) }}
{{- end }}

{{- define "cp.dbPasswordSecretName" -}}
{{- .Values.db.passwordSecret.name | default "straiker-secrets" }}
{{- end }}

{{- define "cp.dbPasswordSecretKey" -}}
{{- .Values.db.passwordSecret.key | default "SYS__PLATFORM_DB_PASSWORD" }}
{{- end }}

{{- define "cp.dbHost" -}}
{{- required "db.host is required" .Values.db.host -}}
{{- end }}

{{- define "cp.opensearchUrl" -}}
{{- if .Values.opensearch.url -}}
{{- .Values.opensearch.url -}}
{{- else -}}
{{- $ns := .Values.global.infraNamespace | default "straiker-infra" -}}
http://opensearch-cluster-master.{{ $ns }}.svc.cluster.local:9200
{{- end -}}
{{- end }}

{{/* Argus detection service — same namespace as control plane. */}}
{{- define "cp.argusEndpoint" -}}
{{- .Values.argusEndpoint | default (printf "http://argus-service.%s.svc.cluster.local" (include "cp.namespace" .)) -}}
{{- end }}

{{/* Iris control-plane admin endpoint — same namespace as control plane. */}}
{{- define "cp.irisAdminEndpoint" -}}
{{- .Values.irisControlPlaneAdminEndpoint | default (printf "http://iris-control-plane-service.%s.svc.cluster.local" (include "cp.namespace" .)) -}}
{{- end }}

{{- define "cp.nodeSelector" -}}
{{- $ns := deepCopy .Values.nodeSelector }}
{{- $arch := .Values.global.arch | default .Values.arch }}
{{- if $arch }}
  {{- $_ := set $ns "kubernetes.io/arch" $arch }}
{{- end }}
{{- if $ns }}
nodeSelector:
  {{- toYaml $ns | nindent 2 }}
{{- end }}
{{- end }}

{{- define "cp.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-control
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Effective ingress class: explicit value wins; falls back to "alb" on EKS.
*/}}
{{- define "cp.ingressClassName" -}}
{{- if .Values.ingress.ingressClassName -}}
{{- .Values.ingress.ingressClassName -}}
{{- else if eq (.Values.global.cloudProvider | default "") "eks" -}}
alb
{{- end -}}
{{- end }}

{{/*
Effective ingress annotations: auto-populate ALB annotations when ingressClassName
resolves to "alb", then merge user-supplied annotations on top (user wins).
*/}}
{{- define "cp.ingressAnnotations" -}}
{{- $a := dict -}}
{{- if eq (include "cp.ingressClassName" .) "alb" -}}
  {{- $_ := set $a "alb.ingress.kubernetes.io/target-type"              "ip" -}}
  {{- $_ := set $a "alb.ingress.kubernetes.io/backend-protocol-version" "HTTP1" -}}
  {{- $_ := set $a "alb.ingress.kubernetes.io/listen-ports"             "[{\"HTTP\": 80}, {\"HTTPS\":443}]" -}}
  {{- $_ := set $a "alb.ingress.kubernetes.io/ssl-redirect"             "443" -}}
  {{- $_ := set $a "alb.ingress.kubernetes.io/ssl-policy"               "ELBSecurityPolicy-TLS13-1-2-2021-06" -}}
  {{- $_ := set $a "alb.ingress.kubernetes.io/healthcheck-path"         "/api/health" -}}
  {{- $_ := set $a "alb.ingress.kubernetes.io/healthcheck-protocol"     "HTTP" -}}
  {{- with .Values.ingress.alb.scheme -}}
    {{- $_ := set $a "alb.ingress.kubernetes.io/scheme" . -}}
  {{- end -}}
  {{- with .Values.ingress.alb.certificateArn -}}
    {{- $_ := set $a "alb.ingress.kubernetes.io/certificate-arn" . -}}
  {{- end -}}
{{- end -}}
{{- $merged := merge (deepCopy (.Values.ingress.annotations | default dict)) $a -}}
{{- if $merged -}}{{ toYaml $merged }}{{- end -}}
{{- end }}
