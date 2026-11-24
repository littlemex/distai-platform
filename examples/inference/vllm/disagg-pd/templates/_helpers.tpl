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
{{- $mps := default (dict "enabled" false "replicas" 2) $r.mps -}}
{{- if $mps.enabled -}}
{{- if lt (int $mps.replicas) 1 -}}
{{- fail (printf "%s.mps.replicas must be at least 1" $role) -}}
{{- end -}}
{{- $ceilingPct := div 90 (int $mps.replicas) -}}
{{- if $r.gpuMemoryUtilization -}}
{{- $explicitPct := int (mulf (float64 $r.gpuMemoryUtilization) 100) -}}
{{- if gt $explicitPct $ceilingPct -}}
{{- fail (printf "%s.gpuMemoryUtilization=%s exceeds the safe ceiling (0.%02d) for %s.mps.replicas=%d -- MPS splits this GPU's memory roughly evenly across replicas. vLLM's own disagg-pd crashed on real hardware at a desired fraction near 0.92 under a 2-replica MPS split (ceiling 0.45), comfortably above this ceiling (distai-platform #37, examples/inference/README.md's own MPS investigation); this chart refuses a value above that ceiling here instead of finding out via a crash loop" $role $r.gpuMemoryUtilization $ceilingPct $role (int $mps.replicas)) -}}
{{- end -}}
{{- end -}}
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

{{/*
  Effective --gpu-memory-utilization for one role (call with that role's own
  values, e.g. .Values.prefill). An explicit value is passed through as-is
  (disagg.validate above already rejected one that does not fit mps.replicas
  when mps.enabled). Otherwise: "" (vLLM's own built-in default, the flag is
  not rendered at all - this chart's behavior before this field existed) when
  mps.enabled is false; a safe computed fraction when it is true. The
  fraction is 0.70/replicas, below the bare 1/replicas MPS itself enforces
  (capacity-pool/README.md's own confirmed pinned-memory-limit log line) and
  below the ceiling disagg.validate enforces (0.90/replicas). This exact
  margin is not derived from a confirmed accounting of every byte this
  chart's own NixlConnector or vLLM's own non-KV-cache memory uses under MPS
  (examples/inference/README.md's own MPS investigation states this as an
  open question, not settled) - 0.70/replicas is a real-hardware-confirmed
  safe value (round 4, #37: this exact fraction started and served a real
  completion on the same shape that crash-looped at vLLM's own un-fixed
  default), picked with headroom below the ceiling rather than derived from
  a full memory-accounting model.
*/}}
{{- define "disagg.gpuMemoryUtilization" -}}
{{- $r := . -}}
{{- $mps := default (dict "enabled" false "replicas" 2) $r.mps -}}
{{- if $r.gpuMemoryUtilization -}}
{{- $r.gpuMemoryUtilization -}}
{{- else if $mps.enabled -}}
{{- printf "0.%02d" (div 70 (int $mps.replicas)) -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}
