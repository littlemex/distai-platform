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

{{- define "agg.validate" -}}
{{- $e := .Values.engine -}}
{{- if lt (int $e.gpusPerEngine) 1 -}}
{{- fail "engine.gpusPerEngine must be at least 1" -}}
{{- end -}}
{{- $cps := int $e.scheduler.chunkedPrefillSize -}}
{{- if or (eq $cps 0) (lt $cps -1) -}}
{{- fail (printf "engine.scheduler.chunkedPrefillSize must be a positive token count (or -1 to disable chunked prefill), got %v" $e.scheduler.chunkedPrefillSize) -}}
{{- end -}}
{{- if and $e.scheduler.enableMixedChunk (eq $cps -1) -}}
{{- fail "engine.scheduler.enableMixedChunk=true needs chunked prefill; engine.scheduler.chunkedPrefillSize=-1 disables it" -}}
{{- end -}}
{{- $kvt := .Values.kvCacheTier -}}
{{- if not (has $kvt.mode (list "gpu-only" "local" "remote")) -}}
{{- fail (printf "kvCacheTier.mode must be gpu-only, local or remote, got %q" $kvt.mode) -}}
{{- end -}}
{{- if eq $kvt.mode "remote" -}}
{{- fail "kvCacheTier.mode=remote is not available for SGLang: its HiCache documents no Redis/ElastiCache backend, so this tier is vLLM-only (RFC #37, Decision 11). Use gpu-only or local" -}}
{{- end -}}
{{- if and (eq $kvt.mode "local") (lt (int $kvt.hicache.sizeGb) 1) -}}
{{- fail "kvCacheTier.mode=local requires kvCacheTier.hicache.sizeGb (the host KV pool per engine, --hicache-size), sized to fit inside engine.resources.requests.memory" -}}
{{- end -}}
{{- end -}}

{{/* SGLang server flags this chart sets, before engine.extraArgs. */}}
{{- define "agg.engineArgs" -}}
{{- $e := .Values.engine -}}
{{- $args := list "--chunked-prefill-size" (toString $e.scheduler.chunkedPrefillSize) -}}
{{- if $e.scheduler.enableMixedChunk -}}
{{- $args = append $args "--enable-mixed-chunk" -}}
{{- end -}}
{{- if .Values.metrics.enabled -}}
{{- $args = append $args "--enable-metrics" -}}
{{- end -}}
{{- if eq .Values.kvCacheTier.mode "local" -}}
{{- $args = concat $args (list "--enable-hierarchical-cache" "--hicache-size" (toString .Values.kvCacheTier.hicache.sizeGb)) .Values.kvCacheTier.hicache.extraArgs -}}
{{- end -}}
{{- toJson (concat $args $e.extraArgs) -}}
{{- end -}}
