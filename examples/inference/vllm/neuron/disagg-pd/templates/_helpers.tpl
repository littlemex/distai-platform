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

{{/*
  Whole Neuron devices one engine of a role requests (call with
  (dict "root" $ "role" $r)): ceil(neuronCoresPerEngine / coresPerDevice).
  The device plugin allocates aws.amazon.com/neuron per device, and the
  tensor parallel degree is counted in NeuronCores, so the two are different
  numbers whenever a device has more than one core.
*/}}
{{- define "disagg.neuronDevices" -}}
{{- $cores := int .role.neuronCoresPerEngine -}}
{{- $per := int .root.Values.accelerator.coresPerDevice -}}
{{- div (add $cores (sub $per 1)) $per -}}
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
{{- if not (has $t.kvRoleMode (list "kv_both" "producer_consumer")) -}}
{{- fail (printf "transport.kvRoleMode must be kv_both or producer_consumer, got %q" $t.kvRoleMode) -}}
{{- end -}}
{{- if eq $t.backend "UCX" -}}
{{- /* Same parsing as ../../disagg-pd/templates/_helpers.tpl: dig + toString so a
  missing transport.ucx or a bare number gets this chart's own message, not a
  template panic. */ -}}
{{- $ucxRange := toString (dig "ucx" "tcpPortRange" "" $t) -}}
{{- if not (regexMatch "^[1-9][0-9]{0,4}-[1-9][0-9]{0,4}$" $ucxRange) -}}
{{- fail (printf "transport.ucx.tcpPortRange must be \"<first>-<last>\" with plain decimal digits only (no leading zero), got %q" $ucxRange) -}}
{{- end -}}
{{- $ucxParts := splitList "-" $ucxRange -}}
{{- $ucxFirst := atoi (index $ucxParts 0) -}}
{{- $ucxLast := atoi (index $ucxParts 1) -}}
{{- if or (lt $ucxFirst 1) (gt $ucxLast 65535) (ge $ucxFirst $ucxLast) -}}
{{- fail (printf "transport.ucx.tcpPortRange=%q must satisfy 1 <= first < last <= 65535" $ucxRange) -}}
{{- end -}}
{{- if gt (sub (add $ucxLast 1) $ucxFirst) 4096 -}}
{{- fail (printf "transport.ucx.tcpPortRange=%q spans more than 4096 ports -- keep this narrow (never something like 1024-65535)" $ucxRange) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.placement.nodeSelectorKey -}}
{{- fail "placement.nodeSelectorKey must not be empty" -}}
{{- end -}}
{{- if lt (int .Values.accelerator.coresPerDevice) 1 -}}
{{- fail "accelerator.coresPerDevice must be at least 1" -}}
{{- end -}}
{{- range $role := list "prefill" "decode" -}}
{{- $r := index $.Values $role -}}
{{- if lt (int $r.replicas) 0 -}}
{{- fail (printf "%s.replicas must not be negative" $role) -}}
{{- end -}}
{{- if lt (int $r.neuronCoresPerEngine) 1 -}}
{{- fail (printf "%s.neuronCoresPerEngine must be at least 1" $role) -}}
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
  The LMCacheMPConnector entry of a MultiConnector's own "connectors" list,
  skeleton only: same rendering as ../../disagg-pd/templates/_helpers.tpl's
  disagg.lmcacheConnector, unverified on Neuron (values.yaml, kvCacheTier).
  Call with the root context ($).
*/}}
{{- define "disagg.lmcacheConnector" -}}
{{- $kvt := .Values.kvCacheTier -}}
{{- $lm := $kvt.lmcache -}}
{{- $parts := splitList ":" $lm.mpServerEndpoint -}}
{{- $cfg := dict "lmcache.mp.host" (printf "tcp://%s" (first $parts)) "lmcache.mp.port" (atoi (last $parts)) -}}
{{- $cfg = merge $cfg (deepCopy $lm.extraConfig) -}}
{{- dict "kv_connector" "LMCacheMPConnector" "kv_role" "kv_both" "kv_connector_extra_config" $cfg | toJson -}}
{{- end -}}
