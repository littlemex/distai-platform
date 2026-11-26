{{/*
JobSet name, also the headless Service name (spec.network.subdomain
defaults to it) and the prefix of every Pod host name
(<name>-worker-<job index>-<pod index>). Truncated to 40 characters so the
longest Pod host name stays within the 63-character DNS label limit.
*/}}
{{- define "ddp.name" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "ddp.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "ddp.image" -}}
{{- $i := .Values.image -}}
{{- if $i.digest -}}
{{ printf "%s:%s@%s" $i.repository $i.tag $i.digest }}
{{- else -}}
{{ printf "%s:%s" $i.repository $i.tag }}
{{- end -}}
{{- end -}}

{{- define "ddp.validate" -}}
{{- $w := .Values.workers -}}
{{- if lt (int $w.replicas) 1 -}}
{{- fail "workers.replicas must be at least 1" -}}
{{- end -}}
{{- if lt (int $w.gpusPerNode) 1 -}}
{{- fail "workers.gpusPerNode must be at least 1" -}}
{{- end -}}
{{- if not .Values.kueue.queueName -}}
{{- fail "kueue.queueName must be set to a LocalQueue in the install namespace" -}}
{{- end -}}
{{- if not (has .Values.failurePolicy.restartStrategy (list "Recreate" "BlockingRecreate")) -}}
{{- fail (printf "failurePolicy.restartStrategy must be Recreate or BlockingRecreate, got %q" .Values.failurePolicy.restartStrategy) -}}
{{- end -}}
{{- if lt (int .Values.training.checkpointEvery) 1 -}}
{{- fail "training.checkpointEvery must be at least 1" -}}
{{- end -}}
{{- end -}}
