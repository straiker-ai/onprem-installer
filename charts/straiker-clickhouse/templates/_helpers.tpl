{{- define "ch.fullname" -}}clickhouse{{- end }}

{{- /* DNS of replica $i, resolvable through the headless Service (also before the pod is ready). */ -}}
{{- define "ch.replicaHost" -}}
{{- printf "%s-%d.%s-headless.%s.svc.cluster.local" (include "ch.fullname" .root) (int .i) (include "ch.fullname" .root) .root.Release.Namespace -}}
{{- end }}

{{- define "ch.keeperName" -}}clickhouse-keeper{{- end }}

{{- /* DNS of Keeper member $i. */ -}}
{{- define "ch.keeperHost" -}}
{{- printf "%s-%d.%s-headless.%s.svc.cluster.local" (include "ch.keeperName" .root) (int .i) (include "ch.keeperName" .root) .root.Release.Namespace -}}
{{- end }}

{{- /* Replication is on when there is more than one replica. */ -}}
{{- define "ch.replicated" -}}
{{- if and (gt (int .Values.replicas) 1) .Values.keeper.enabled -}}true{{- end -}}
{{- end }}
