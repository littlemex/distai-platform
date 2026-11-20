{{/* Release-scoped base name, at most 52 characters so "-prefill" etc. fit. */}}
{{- define "disagg.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "disagg.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Selector labels for one component; call with (dict "root" $ "component" "prefill"). */}}
{{- define "disagg.selector" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "disagg.image" -}}
{{- $i := .Values.image -}}
{{- if $i.digest -}}
{{ printf "%s:%s@%s" $i.repository $i.tag $i.digest }}
{{- else -}}
{{ printf "%s:%s" $i.repository $i.tag }}
{{- end -}}
{{- end -}}

{{/* Fail rendering on value combinations that would deploy something other than what they say. */}}
{{- define "disagg.validate" -}}
{{- $t := .Values.transport -}}
{{- if not (has $t.backend (list "LIBFABRIC" "UCX")) -}}
{{- fail (printf "transport.backend must be LIBFABRIC or UCX, got %q" $t.backend) -}}
{{- end -}}
{{- if and $t.forceEfaSameNode (ne $t.backend "LIBFABRIC") -}}
{{- fail "transport.forceEfaSameNode=true only has an effect with transport.backend=LIBFABRIC" -}}
{{- end -}}
{{- if and $t.forceEfaSameNode (not .Values.placement.sameNodeMeasurement) -}}
{{- fail "transport.forceEfaSameNode=true only makes sense with placement.sameNodeMeasurement=true; a cross-node run already uses the EFA device path" -}}
{{- end -}}
{{- if not (has $t.kvLoadFailurePolicy (list "fail" "recompute")) -}}
{{- fail (printf "transport.kvLoadFailurePolicy must be fail or recompute, got %q" $t.kvLoadFailurePolicy) -}}
{{- end -}}
{{- if not .Values.placement.nodeSelectorKey -}}
{{- fail "placement.nodeSelectorKey must not be empty" -}}
{{- end -}}
{{- range $role := list "prefill" "decode" -}}
{{- $r := index $.Values $role -}}
{{- if lt (int $r.replicas) 0 -}}
{{- fail (printf "%s.replicas must not be negative" $role) -}}
{{- end -}}
{{- if lt (int $r.gpusPerEngine) 1 -}}
{{- fail (printf "%s.gpusPerEngine must be at least 1" $role) -}}
{{- end -}}
{{- if not $r.nodeSelectorValue -}}
{{- fail (printf "%s.nodeSelectorValue must not be empty" $role) -}}
{{- end -}}
{{- if and (eq $t.backend "LIBFABRIC") (lt (int $r.efaDevices) 1) -}}
{{- fail (printf "%s.efaDevices must be at least 1 with transport.backend=LIBFABRIC (FI_PROVIDER=efa needs an EFA device)" $role) -}}
{{- end -}}
{{- end -}}
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
{{- end -}}

{{/*
  The LMCacheMPConnector entry of a MultiConnector's own "connectors" list
  (vLLM's confirmed stacking shape, docs.vllm.ai "disaggregated prefilling",
  fetched 2026-11-21), skeleton only - see values.yaml's own kvCacheTier
  comment for what is and is not confirmed about the exact config keys
  below, and for why local and remote render identically here. "tcp://" is
  prepended to the host explicitly (LMCache's own mp configuration
  confirms a scheme is required on lmcache.mp.host - docs.lmcache.ai/mp/configuration.html,
  fetched 2026-11-21 - rather than relying on that doc's own, narrower
  "a bare localhost/127.0.0.1 is normalized" note, which this chart does
  not read as covering an arbitrary hostname). grpc:// is a documented
  alternative transport this chart does not expose a value for. Call with
  the root context ($).
*/}}
{{- define "disagg.lmcacheConnector" -}}
{{- $kvt := .Values.kvCacheTier -}}
{{- $lm := $kvt.lmcache -}}
{{- $parts := splitList ":" $lm.mpServerEndpoint -}}
{{- $cfg := dict "lmcache.mp.host" (printf "tcp://%s" (first $parts)) "lmcache.mp.port" (atoi (last $parts)) -}}
{{- $cfg = merge $cfg (deepCopy $lm.extraConfig) -}}
{{- dict "kv_connector" "LMCacheMPConnector" "kv_role" "kv_both" "kv_connector_extra_config" $cfg | toJson -}}
{{- end -}}
