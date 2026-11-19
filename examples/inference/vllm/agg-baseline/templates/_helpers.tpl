{{- define "agg.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "agg.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/component: aggregated
{{- end -}}

{{- define "agg.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: aggregated
{{- end -}}

{{- define "agg.image" -}}
{{- $i := .Values.image -}}
{{- if $i.digest -}}
{{ printf "%s:%s@%s" $i.repository $i.tag $i.digest }}
{{- else -}}
{{ printf "%s:%s" $i.repository $i.tag }}
{{- end -}}
{{- end -}}
