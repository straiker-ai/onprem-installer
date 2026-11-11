{{- define "chsync.env" -}}
- { name: CH_HOST, valueFrom: { secretKeyRef: { name: {{ .Values.clickhouse.credentialsSecret }}, key: ddlHost } } }
- { name: CH_REPLICATED, value: {{ .Values.clickhouse.replicated | quote }} }
- { name: CH_PORT, valueFrom: { secretKeyRef: { name: {{ .Values.clickhouse.credentialsSecret }}, key: nativePort } } }
- { name: CH_USER, valueFrom: { secretKeyRef: { name: {{ .Values.clickhouse.credentialsSecret }}, key: admin_username } } }
- { name: CH_PASSWORD, valueFrom: { secretKeyRef: { name: {{ .Values.clickhouse.credentialsSecret }}, key: admin_password } } }
- { name: PG_HOST, value: {{ required "postgres.host is required" .Values.postgres.host | quote }} }
- { name: PG_PORT, value: {{ .Values.postgres.port | quote }} }
- { name: PG_DATABASE, value: {{ .Values.postgres.database | quote }} }
- { name: PG_SCHEMA, value: {{ .Values.postgres.schema | quote }} }
- { name: PG_USER, value: {{ .Values.postgres.username | quote }} }
- { name: PG_PASSWORD, valueFrom: { secretKeyRef: { name: {{ .Values.postgres.passwordSecret }}, key: {{ .Values.postgres.passwordKey }} } } }
- { name: OPTIMIZE_HOURLY, value: {{ .Values.optimizeHourly | quote }} }
{{- end }}
