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
{{- $kvt := .Values.kvCacheTier -}}
{{- if not (has $kvt.mode (list "gpu-only" "local" "remote")) -}}
{{- fail (printf "kvCacheTier.mode must be gpu-only, local or remote, got %q" $kvt.mode) -}}
{{- end -}}
{{- if and (ne $kvt.mode "gpu-only") (not $kvt.lmcache.mpServerEndpoint) -}}
{{- fail "kvCacheTier.mode=local or remote requires kvCacheTier.lmcache.mpServerEndpoint (host:port of LMCache's own mp server)" -}}
{{- end -}}
{{- if and $kvt.lmcache.mpServerEndpoint (not (regexMatch "^[^:/]+:[0-9]+$" $kvt.lmcache.mpServerEndpoint)) -}}
{{- fail (printf "kvCacheTier.lmcache.mpServerEndpoint must be host:port with a numeric port and no scheme (the chart adds tcp:// itself), got %q" $kvt.lmcache.mpServerEndpoint) -}}
{{- end -}}
{{- $mps := default (dict "enabled" false "replicas" 2) .Values.engine.mps -}}
{{- if $mps.enabled -}}
{{- if lt (int $mps.replicas) 1 -}}
{{- fail "engine.mps.replicas must be at least 1" -}}
{{- end -}}
{{- $ceilingPct := div 90 (int $mps.replicas) -}}
{{- if .Values.engine.gpuMemoryUtilization -}}
{{- $explicitPct := int (mulf (float64 .Values.engine.gpuMemoryUtilization) 100) -}}
{{- if gt $explicitPct $ceilingPct -}}
{{- fail (printf "engine.gpuMemoryUtilization=%s exceeds the safe ceiling (0.%02d) for engine.mps.replicas=%d -- MPS splits this GPU's memory roughly evenly across replicas. vLLM's own disagg-pd crashed on real hardware at a desired fraction near 0.92 under a 2-replica MPS split (ceiling 0.45), comfortably above this ceiling (distai-platform #37, examples/inference/README.md's own MPS investigation); this chart refuses a value above that ceiling here instead of finding out via a crash loop" .Values.engine.gpuMemoryUtilization $ceilingPct (int $mps.replicas)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
  Effective --gpu-memory-utilization (call with .Values.engine). Same shape
  and same 0.70/replicas default as ../disagg-pd/templates/_helpers.tpl's
  own disagg.gpuMemoryUtilization. This chart's own default (gpu-only)
  renders no kv-transfer-config at all (see engine.yaml), unlike disagg-pd's
  mandatory NixlConnector; whether that difference is why disagg-pd's own
  un-fixed default crashes under MPS while this chart's own un-fixed default
  does not is an open question (examples/inference/README.md's own MPS
  investigation states it as a candidate, not confirmed) - this chart kept
  the same 0.70/replicas formula as disagg-pd for one rule a reader of both
  charts can hold in their head, not because this chart's own real-hardware
  evidence requires a less conservative number.
*/}}
{{- define "agg.gpuMemoryUtilization" -}}
{{- $e := . -}}
{{- $mps := default (dict "enabled" false "replicas" 2) $e.mps -}}
{{- if $e.gpuMemoryUtilization -}}
{{- $e.gpuMemoryUtilization -}}
{{- else if $mps.enabled -}}
{{- printf "0.%02d" (div 70 (int $mps.replicas)) -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}

{{/* Skeleton only; see ../disagg-pd/templates/_helpers.tpl's own
     disagg.lmcacheConnector for what is and is not confirmed, and for why
     local and remote render identically. */}}
{{- define "agg.lmcacheConnector" -}}
{{- $kvt := .Values.kvCacheTier -}}
{{- $lm := $kvt.lmcache -}}
{{- $parts := splitList ":" $lm.mpServerEndpoint -}}
{{- $cfg := dict "lmcache.mp.host" (printf "tcp://%s" (first $parts)) "lmcache.mp.port" (atoi (last $parts)) -}}
{{- $cfg = merge $cfg (deepCopy $lm.extraConfig) -}}
{{- dict "kv_connector" "LMCacheMPConnector" "kv_role" "kv_both" "kv_connector_extra_config" $cfg | toJson -}}
{{- end -}}
