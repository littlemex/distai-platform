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
{{- if and (eq $kvt.mode "remote") (not $kvt.lmcache.remote.endpoint) -}}
{{- fail "kvCacheTier.mode=remote requires kvCacheTier.lmcache.remote.endpoint" -}}
{{- end -}}
{{- if not (has $kvt.lmcache.localBackend (list "cpu" "disk")) -}}
{{- fail (printf "kvCacheTier.lmcache.localBackend must be cpu or disk, got %q" $kvt.lmcache.localBackend) -}}
{{- end -}}
{{- end -}}

{{/* Skeleton only; see ../disagg-pd/templates/_helpers.tpl's own
     disagg.lmcacheConnector for what is and is not confirmed. */}}
{{- define "agg.lmcacheConnector" -}}
{{- $kvt := .Values.kvCacheTier -}}
{{- $lm := $kvt.lmcache -}}
{{- $cfg := dict "chunk_size" (int $lm.chunkSize) "hash_algorithm" $lm.hashAlgorithm "local_cpu" (eq $lm.localBackend "cpu") -}}
{{- if eq $kvt.mode "remote" -}}
{{- $_ := set $cfg "remote_url" $lm.remote.endpoint -}}
{{- $_ := set $cfg "remote_enable_tls" $lm.remote.enableTls -}}
{{- end -}}
{{- $cfg = merge $cfg (deepCopy $lm.extraConfig) -}}
{{- dict "kv_connector" "LMCacheConnector" "kv_role" "kv_both" "kv_connector_extra_config" $cfg | toJson -}}
{{- end -}}
