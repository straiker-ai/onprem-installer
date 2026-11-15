{{- /* Called with (dict "root" . "user" "<clickhouse user>"): the init Job needs DDL rights (admin), the CronJob only grid_sync. */ -}}
{{- define "chsync.env" -}}
{{- $r := .root -}}
{{- $u := .user -}}
- { name: CH_HOST, valueFrom: { secretKeyRef: { name: {{ $r.Values.clickhouse.credentialsSecret }}, key: ddlHost } } }
- { name: CH_REPLICATED, value: {{ $r.Values.clickhouse.replicated | quote }} }
- { name: CH_PORT, valueFrom: { secretKeyRef: { name: {{ $r.Values.clickhouse.credentialsSecret }}, key: nativePort } } }
- { name: CH_USER, valueFrom: { secretKeyRef: { name: {{ $r.Values.clickhouse.credentialsSecret }}, key: {{ $u }}_username } } }
- { name: CH_PASSWORD, valueFrom: { secretKeyRef: { name: {{ $r.Values.clickhouse.credentialsSecret }}, key: {{ $u }}_password } } }
- { name: PG_HOST, value: {{ required "postgres.host is required" $r.Values.postgres.host | quote }} }
- { name: PG_PORT, value: {{ $r.Values.postgres.port | quote }} }
- { name: PG_DATABASE, value: {{ $r.Values.postgres.database | quote }} }
- { name: PG_SCHEMA, value: {{ $r.Values.postgres.schema | quote }} }
- { name: PG_USER, value: {{ $r.Values.postgres.username | quote }} }
- { name: PG_PASSWORD, valueFrom: { secretKeyRef: { name: {{ $r.Values.postgres.passwordSecret }}, key: {{ $r.Values.postgres.passwordKey }} } } }
- { name: OPTIMIZE_HOURLY, value: {{ $r.Values.optimizeHourly | quote }} }
{{- end }}
