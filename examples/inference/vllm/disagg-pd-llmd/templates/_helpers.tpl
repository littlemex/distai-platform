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
{{- $ucxParts := splitList "-" $t.ucx.tcpPortRange -}}
{{- if ne (len $ucxParts) 2 -}}
{{- fail (printf "transport.ucx.tcpPortRange must be \"<first>-<last>\", got %q" $t.ucx.tcpPortRange) -}}
{{- end -}}
{{- $ucxFirst := int (index $ucxParts 0) -}}
{{- $ucxLast := int (index $ucxParts 1) -}}
{{- if or (lt $ucxFirst 1) (gt $ucxLast 65535) (ge $ucxFirst $ucxLast) -}}
{{- fail (printf "transport.ucx.tcpPortRange=%q must satisfy 1 <= first < last <= 65535" $t.ucx.tcpPortRange) -}}
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
  values, e.g. .Values.prefill). Same shape and rationale as
  ../disagg-pd/templates/_helpers.tpl's own disagg.gpuMemoryUtilization
  (0.70/replicas default, below the bare 1/replicas MPS enforces and below
  the 0.90/replicas ceiling disagg.validate enforces; see that file's own
  comment for why the exact margin is not derived from a confirmed memory
  accounting, only from real-hardware confirmation that this fraction
  starts and serves a real completion on the shape that otherwise
  crash-loops, #37); kept as a separate copy rather than a shared partial
  because this chart has no dependency on ../disagg-pd today.
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

{{/* ---- llm-d routing: everything below exists only in this chart. ---- */}}

{{- define "disagg.sidecarImage" -}}
{{- $i := .Values.routingSidecar.image -}}
{{- if $i.digest -}}
{{ printf "%s:%s@%s" $i.repository $i.tag $i.digest }}
{{- else -}}
{{ printf "%s:%s" $i.repository $i.tag }}
{{- end -}}
{{- end -}}

{{/*
  Name of the InferencePool the router chart renders. The router chart
  (llm-d-router-gateway v1.0.0, routerlib templates/_inferencepool.yaml)
  names it after the release, and this chart runs it as a subchart, so its
  .Release.Name is this release's name. The routing sidecar's
  --inference-pool flag must name the same object.
*/}}
{{- define "disagg.inferencePoolName" -}}
{{- .Release.Name -}}
{{- end -}}

{{/* Fail rendering on llm-d routing values that would deploy something other than what they say. */}}
{{- define "disagg.validateRouting" -}}
{{- $ms := .Values.llmdRouter.router.modelServers -}}
{{- if not $ms.matchLabels -}}
{{- fail "llmdRouter.router.modelServers.matchLabels must not be empty: it is the InferencePool's pod selector, and this chart also stamps it on every engine pod" -}}
{{- end -}}
{{- if hasKey $ms.matchLabels "llm-d.ai/role" -}}
{{- fail "llmdRouter.router.modelServers.matchLabels must not contain llm-d.ai/role: the pool has to select both roles, and the chart sets that label per role itself" -}}
{{- end -}}
{{- $ports := list -}}
{{- range $ms.targetPorts -}}
{{- $ports = append $ports (int .number) -}}
{{- end -}}
{{- if ne (toJson $ports) (toJson (list (int .Values.engine.port))) -}}
{{- fail (printf "llmdRouter.router.modelServers.targetPorts must be exactly [engine.port] (%d), got %s: the EPP sends every request to that port, where a prefill pod's vLLM and a decode pod's routing sidecar listen" (int .Values.engine.port) (toJson $ports)) -}}
{{- end -}}
{{- if eq (int .Values.routingSidecar.enginePort) (int .Values.engine.port) -}}
{{- fail "routingSidecar.enginePort must differ from engine.port: on a decode pod the sidecar listens on engine.port and vLLM behind it on routingSidecar.enginePort" -}}
{{- end -}}
{{- if or (eq (int .Values.routingSidecar.metricsPort) (int .Values.engine.port)) (eq (int .Values.routingSidecar.metricsPort) (int .Values.routingSidecar.enginePort)) -}}
{{- fail "routingSidecar.metricsPort must differ from engine.port and routingSidecar.enginePort" -}}
{{- end -}}
{{- if ne (toString .Values.llmdRouter.router.inferencePool.failureMode) "FailClose" -}}
{{- if ne (toString .Values.llmdRouter.router.inferencePool.failureMode) "FailOpen" -}}
{{- fail (printf "llmdRouter.router.inferencePool.failureMode must be FailClose or FailOpen, got %q" (toString .Values.llmdRouter.router.inferencePool.failureMode)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
