{{- /* kafka_franz connection block shared by every input/DLQ output (indent set by the caller). */ -}}
{{- define "ingest.kafka" -}}
seed_brokers: [ ${BROKERS} ]
{{- if or .Values.bus.tls (eq .Values.bus.sasl.mechanism "aws_msk_iam") }}
tls: { enabled: true }
{{- end }}
{{- if eq .Values.bus.sasl.mechanism "aws_msk_iam" }}
sasl:
  - mechanism: AWS_MSK_IAM
    aws: { region: {{ required "bus.sasl.region is required for aws_msk_iam" .Values.bus.sasl.region | quote }} }
{{- end }}
{{- end }}

{{- /* Shared output: mapping errors -> <topic>.dlq; otherwise batched NDJSON INSERT, falling back to the DLQ if ClickHouse rejects it. */ -}}
{{- define "ingest.output" -}}
{{- $ctx := .ctx -}}
switch:
  cases:
    - check: errored()
      output:
        kafka_franz:
{{ include "ingest.kafka" $ctx | indent 10 }}
          topic: {{ .topic }}.dlq
    - output:
        fallback:
          - http_client:
              url: http://${CH_HOST}:${CH_HTTP_PORT}/?database={{ $ctx.Values.clickhouse.database }}&query=INSERT%20INTO%20{{ .table }}%20FORMAT%20JSONEachRow&date_time_input_format=best_effort&input_format_skip_unknown_fields=1
              verb: POST
              headers:
                X-ClickHouse-User: ${CH_USER}
                X-ClickHouse-Key: ${CH_PASSWORD}
                Content-Type: application/x-ndjson
              timeout: 30s
              retries: 3
              batching:
                count: {{ $ctx.Values.batch.count }}
                period: {{ $ctx.Values.batch.period }}
                processors:
                  - archive: { format: lines }
          - kafka_franz:
{{ include "ingest.kafka" $ctx | indent 14 }}
              topic: {{ .topic }}.dlq
{{- end }}
