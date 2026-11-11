{{/*
Database -> Aurora cluster, as JSON ({"iris":"ascend","registry":"platform",...}).
A database's cluster (default "platform") falls back to "platform" while that
cluster's host is not set, so an install with a single Aurora cluster keeps working.
*/}}
{{- define "straiker-data.dbClusters" -}}
{{- $out := dict -}}
{{- range $db, $cfg := .Values.databases -}}
{{- $target := default "platform" $cfg.cluster -}}
{{- $cl := default (dict) (get $.Values.aurora.clusters $target) -}}
{{- if not $cl.host -}}{{- $target = "platform" -}}{{- end -}}
{{- $_ := set $out $db $target -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
