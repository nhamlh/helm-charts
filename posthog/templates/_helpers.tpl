{{/*
Expand the name of the chart.
*/}}
{{- define "posthog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "posthog.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
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
Chart label values.
*/}}
{{- define "posthog.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "posthog.labels" -}}
helm.sh/chart: {{ include "posthog.chart" . }}
{{ include "posthog.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — use these in matchLabels, not the full label set.
*/}}
{{- define "posthog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "posthog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "posthog.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "posthog.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Service account name used by pre-install/pre-upgrade hook Jobs
(migrate/init). This is a separate, ephemeral ServiceAccount so the
workload ServiceAccount can be a normal Helm-managed resource with a
stable UID (recreating it on every upgrade invalidates the bound
tokens of long-running pods such as personhog-router).
*/}}
{{- define "posthog.hookServiceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- printf "%s-hooks" (include "posthog.serviceAccountName" .) }}
{{- else }}
{{- include "posthog.serviceAccountName" . }}
{{- end }}
{{- end }}

{{/*
Component fullname — "release-chart-component".
*/}}
{{- define "posthog.component.fullname" -}}
{{- printf "%s-%s" (include "posthog.fullname" .) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Convert the shared logging.level (warn/info/debug/error) to a Django log level.
Django uses WARNING; all other levels uppercased are already canonical.
*/}}
{{- define "posthog.django.logLevel" -}}
{{- if eq .Values.logging.level "warn" }}WARNING{{ else }}{{ .Values.logging.level | upper }}{{ end }}
{{- end }}

{{/*
Django (web/worker) environment — shared base env vars.
*/}}
{{- define "posthog.django.env" -}}
- name: DATABASE_URL
  value: {{ .Values.postgres.url | quote }}
- name: REDIS_URL
  value: {{ .Values.redis.url | quote }}
- name: SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "posthog.fullname" . }}-secrets
      key: secretKey
- name: ENCRYPTION_SALT_KEYS
  valueFrom:
    secretKeyRef:
      name: {{ include "posthog.fullname" . }}-secrets
      key: encryptionSaltKeys
- name: CLICKHOUSE_HOST
  value: {{ .Values.clickhouse.host | quote }}
- name: CLICKHOUSE_DATABASE
  value: {{ .Values.clickhouse.database | quote }}
- name: CLICKHOUSE_USER
  value: {{ .Values.clickhouse.user | quote }}
- name: CLICKHOUSE_PASSWORD
  value: {{ .Values.clickhouse.password | quote }}
- name: CLICKHOUSE_CLUSTER
  value: {{ .Values.clickhouse.cluster | quote }}
- name: CLICKHOUSE_SECURE
  value: {{ .Values.clickhouse.secure | quote }}
- name: CLICKHOUSE_VERIFY
  value: {{ .Values.clickhouse.verify | quote }}
{{- if .Values.clickhouse.ca }}
- name: CLICKHOUSE_CA
  value: {{ .Values.clickhouse.ca | quote }}
{{- end }}
- name: KAFKA_HOSTS
  value: {{ .Values.kafka.hosts | quote }}
{{- if .Values.kafka.securityProtocol }}
- name: KAFKA_SECURITY_PROTOCOL
  value: {{ .Values.kafka.securityProtocol | quote }}
{{- end }}
{{- if .Values.kafka.saslMechanism }}
- name: KAFKA_SASL_MECHANISM
  value: {{ .Values.kafka.saslMechanism | quote }}
- name: KAFKA_SASL_USER
  value: {{ .Values.kafka.saslUser | quote }}
- name: KAFKA_SASL_PASSWORD
  value: {{ .Values.kafka.saslPassword | quote }}
{{- end }}
- name: SITE_URL
  value: {{ .Values.siteUrl | quote }}
- name: PERSONHOG_ADDR
  value: "{{ include "posthog.component.fullname" (dict "component" "personhog-router" "Chart" .Chart "Release" .Release "Values" .Values) }}:50052"
- name: PERSONHOG_ENABLED
  value: "true"
- name: INTERNAL_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "posthog.fullname" . }}-secrets
      key: internalApiSecret
- name: DJANGO_LOG_LEVEL
  value: {{ include "posthog.django.logLevel" . | quote }}
{{- if .Values.postgres.usingPgbouncer }}
- name: USING_PGBOUNCER
  value: "true"
{{- end }}
{{- if .Values.postgres.directHost }}
- name: POSTHOG_POSTGRES_DIRECT_HOST
  value: {{ .Values.postgres.directHost | quote }}
{{- end }}
{{- if .Values.deployment }}
- name: DEPLOYMENT
  value: {{ .Values.deployment | quote }}
{{- end }}
{{- if .Values.objectStorage.enabled }}
- name: OBJECT_STORAGE_ENABLED
  value: "true"
- name: OBJECT_STORAGE_ENDPOINT
  value: {{ .Values.objectStorage.endpoint | quote }}
- name: OBJECT_STORAGE_ACCESS_KEY_ID
  value: {{ .Values.objectStorage.accessKeyId | quote }}
- name: OBJECT_STORAGE_SECRET_ACCESS_KEY
  value: {{ .Values.objectStorage.secretAccessKey | quote }}
- name: OBJECT_STORAGE_BUCKET
  value: {{ .Values.objectStorage.bucket | quote }}
{{- if .Values.objectStorage.region }}
- name: OBJECT_STORAGE_REGION
  value: {{ .Values.objectStorage.region | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Node.js ingestion services — shared base env vars.
*/}}
{{- define "posthog.node.env" -}}
- name: DATABASE_URL
  value: {{ .Values.postgres.url | quote }}
- name: REDIS_URL
  value: {{ .Values.redis.url | quote }}
- name: KAFKA_HOSTS
  value: {{ .Values.kafka.hosts | quote }}
{{- /* Per-slot consumer/producer broker lists all default to kafka.hosts —
       the node image otherwise falls back to localhost for these slots. */}}
- name: KAFKA_CONSUMER_METADATA_BROKER_LIST
  value: {{ .Values.kafka.hosts | quote }}
- name: KAFKA_PRODUCER_METADATA_BROKER_LIST
  value: {{ .Values.kafka.hosts | quote }}
{{- range list "INGESTION_UPSTREAM" "INGESTION_DOWNSTREAM" "WARPSTREAM_INGESTION" "WARPSTREAM_CYCLOTRON" "WARPSTREAM_CALCULATED_EVENTS" "WAREHOUSE" }}
- name: KAFKA_{{ . }}_PRODUCER_METADATA_BROKER_LIST
  value: {{ $.Values.kafka.hosts | quote }}
{{- end }}
- name: CLICKHOUSE_HOST
  value: {{ .Values.clickhouse.host | quote }}
- name: CLICKHOUSE_DATABASE
  value: {{ .Values.clickhouse.database | quote }}
- name: CLICKHOUSE_USER
  value: {{ .Values.clickhouse.user | quote }}
- name: CLICKHOUSE_PASSWORD
  value: {{ .Values.clickhouse.password | quote }}
{{- /* CDP Redis (hog-transformer) defaults to 127.0.0.1 in the node image */}}
{{- if .Values.redis.cdpHost }}
- name: CDP_REDIS_HOST
  value: {{ .Values.redis.cdpHost | quote }}
- name: CDP_REDIS_PORT
  value: {{ .Values.redis.cdpPort | default "6379" | quote }}
{{- end }}
- name: ENCRYPTION_SALT_KEYS
  valueFrom:
    secretKeyRef:
      name: {{ include "posthog.fullname" . }}-secrets
      key: encryptionSaltKeys
- name: PERSONHOG_ADDR
  value: "{{ include "posthog.component.fullname" (dict "component" "personhog-router" "Chart" .Chart "Release" .Release "Values" .Values) }}:50052"
- name: PERSONHOG_ENABLED
  value: "true"
- name: INTERNAL_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "posthog.fullname" . }}-secrets
      key: internalApiSecret
- name: LOG_LEVEL
  value: {{ .Values.logging.level | quote }}
{{- if .Values.kafka.securityProtocol }}
- name: KAFKA_SECURITY_PROTOCOL
  value: {{ .Values.kafka.securityProtocol | quote }}
- name: KAFKA_SASL_MECHANISM
  value: {{ .Values.kafka.saslMechanism | quote }}
- name: KAFKA_SASL_USER
  value: {{ .Values.kafka.saslUser | quote }}
- name: KAFKA_SASL_PASSWORD
  value: {{ .Values.kafka.saslPassword | quote }}
{{- end }}
{{- if .Values.postgres.personsUrl }}
- name: PERSONS_DATABASE_URL
  value: {{ .Values.postgres.personsUrl | quote }}
{{- end }}
{{- if .Values.postgres.behavioralCohortsUrl }}
- name: BEHAVIORAL_COHORTS_DATABASE_URL
  value: {{ .Values.postgres.behavioralCohortsUrl | quote }}
{{- end }}
{{- end }}

{{/*
Rust services — shared base env vars.
*/}}
{{- define "posthog.rust.env" -}}
- name: KAFKA_HOSTS
  value: {{ .Values.kafka.hosts | quote }}
- name: REDIS_URL
  value: {{ .Values.redis.url | quote }}
- name: CLICKHOUSE_HOST
  value: {{ .Values.clickhouse.host | quote }}
- name: CLICKHOUSE_DATABASE
  value: {{ .Values.clickhouse.database | quote }}
- name: CLICKHOUSE_USER
  value: {{ .Values.clickhouse.user | quote }}
- name: CLICKHOUSE_PASSWORD
  value: {{ .Values.clickhouse.password | quote }}
{{- if .Values.kafka.securityProtocol }}
- name: KAFKA_SECURITY_PROTOCOL
  value: {{ .Values.kafka.securityProtocol | quote }}
{{- end }}
- name: RUST_LOG
  value: {{ .Values.logging.level | quote }}
{{- end }}
