{{- define "edge.namespace" -}}{{ .Release.Namespace }}{{- end }}

{{- define "edge.image" -}}
{{- $registry := .Values.global.dockerRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" ($registry | trimSuffix "/") .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end }}

{{- define "edge.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: straiker-edge
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "edge.nodeSelector" -}}
{{- .Values.nodeSelector | default .Values.global.sharedNodeSelector | toYaml -}}
{{- end }}

{{- /* xalb: listener/ALB-wide annotations shared by every Ingress of the IngressGroup. The controller requires the
       same value on each member (or on one only), so templates/xalb-ingress.yaml renders them from here. */}}
{{- define "edge.xalbGroupAnnotations" -}}
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
alb.ingress.kubernetes.io/group.name: {{ required "xalb.groupName is required when edgeType=xalb" .Values.xalb.groupName | quote }}
{{- if .Values.xalb.sslPolicy }}
alb.ingress.kubernetes.io/ssl-policy: {{ .Values.xalb.sslPolicy | quote }}
{{- end }}
{{- if .Values.xalb.idleTimeoutSeconds }}
alb.ingress.kubernetes.io/load-balancer-attributes: {{ printf "idle_timeout.timeout_seconds=%v" .Values.xalb.idleTimeoutSeconds | quote }}
{{- end }}
{{- if .Values.waf.webAclArn }}
alb.ingress.kubernetes.io/wafv2-acl-arn: {{ .Values.waf.webAclArn | quote }}
{{- end }}
{{- end }}
