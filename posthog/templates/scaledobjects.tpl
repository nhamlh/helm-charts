{{- $root := . -}}
{{- $components := list
  (dict "key" "web" "name" "web" "enabled" true)
  (dict "key" "worker" "name" "worker" "enabled" true)
  (dict "key" "capture" "name" "capture" "enabled" true)
  (dict "key" "ingestionGeneral" "name" "ingestion-general" "enabled" true)
  (dict "key" "featureFlags" "name" "feature-flags" "enabled" true)
  (dict "key" "personhogReplica" "name" "personhog-replica" "enabled" true)
  (dict "key" "personhogRouter" "name" "personhog-router" "enabled" true)
  (dict "key" "plugins" "name" "plugins" "enabled" true)
  (dict "key" "cyclotronJanitor" "name" "cyclotron-janitor" "enabled" true)
  (dict "key" "replayCapture" "name" "replay-capture" "enabled" .Values.features.sessionReplay.enabled)
  (dict "key" "ingestionSessionReplay" "name" "ingestion-sessionreplay" "enabled" .Values.features.sessionReplay.enabled)
  (dict "key" "recordingApi" "name" "recording-api" "enabled" .Values.features.sessionReplay.enabled)
  (dict "key" "ingestionErrorTracking" "name" "ingestion-error-tracking" "enabled" .Values.features.errorTracking.enabled)
  (dict "key" "cymbal" "name" "cymbal" "enabled" .Values.features.errorTracking.enabled)
  (dict "key" "ingestionLogs" "name" "ingestion-logs" "enabled" .Values.features.logs.enabled)
  (dict "key" "ingestionTraces" "name" "ingestion-traces" "enabled" .Values.features.traces.enabled)
  (dict "key" "captureAi" "name" "capture-ai" "enabled" .Values.features.aiCapture.enabled)
  (dict "key" "captureLogs" "name" "capture-logs" "enabled" .Values.features.captureLogs.enabled)
  (dict "key" "propertyDefs" "name" "property-defs-rs" "enabled" .Values.features.propertyDefs.enabled)
  (dict "key" "hypercache" "name" "hypercache-server" "enabled" .Values.features.hypercache.enabled)
  (dict "key" "livestream" "name" "livestream" "enabled" .Values.features.livestream.enabled)
  (dict "key" "temporalDjangoWorker" "name" "temporal-django-worker" "enabled" .Values.features.temporal.enabled)
-}}
{{- range $components }}
{{- $componentKey := .key -}}
{{- $componentName := .name -}}
{{- $componentValues := default dict (get $root.Values $componentKey) -}}
{{- $autoscaling := default dict (coalesce (get $componentValues "autoscaling") $root.Values.autoscaling) -}}
{{- if and .enabled $autoscaling.enabled }}
{{- if not $autoscaling.triggers }}
{{- fail (printf "%s.autoscaling.triggers must be set when enabled" $componentKey) }}
{{- end }}
{{- $scaleTargetRef := default dict $autoscaling.scaleTargetRef -}}
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: {{ default (include "posthog.component.fullname" (dict "component" $componentName "Chart" $root.Chart "Release" $root.Release "Values" $root.Values)) $autoscaling.nameOverride }}
  labels:
    {{- include "posthog.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $componentName }}
  {{- with $autoscaling.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  scaleTargetRef:
    apiVersion: {{ default "apps/v1" $scaleTargetRef.apiVersion }}
    kind: {{ default "Deployment" $scaleTargetRef.kind }}
    name: {{ default (include "posthog.component.fullname" (dict "component" $componentName "Chart" $root.Chart "Release" $root.Release "Values" $root.Values)) $scaleTargetRef.name }}
    {{- with $scaleTargetRef.envSourceContainerName }}
    envSourceContainerName: {{ . }}
    {{- end }}
  {{- if hasKey $autoscaling "pollingInterval" }}
  pollingInterval: {{ $autoscaling.pollingInterval }}
  {{- end }}
  {{- if hasKey $autoscaling "cooldownPeriod" }}
  cooldownPeriod: {{ $autoscaling.cooldownPeriod }}
  {{- end }}
  {{- if hasKey $autoscaling "initialCooldownPeriod" }}
  initialCooldownPeriod: {{ $autoscaling.initialCooldownPeriod }}
  {{- end }}
  {{- if hasKey $autoscaling "idleReplicaCount" }}
  idleReplicaCount: {{ $autoscaling.idleReplicaCount }}
  {{- end }}
  {{- if hasKey $autoscaling "minReplicaCount" }}
  minReplicaCount: {{ $autoscaling.minReplicaCount }}
  {{- end }}
  {{- if hasKey $autoscaling "maxReplicaCount" }}
  maxReplicaCount: {{ $autoscaling.maxReplicaCount }}
  {{- end }}
  {{- with $autoscaling.fallback }}
  fallback:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $autoscaling.advanced }}
  advanced:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  triggers:
    {{- toYaml $autoscaling.triggers | nindent 4 }}
{{ end }}
{{ end }}
