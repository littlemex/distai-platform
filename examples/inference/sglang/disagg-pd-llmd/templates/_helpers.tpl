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

{{- define "disagg.sidecarImage" -}}
{{- $i := .Values.routingSidecar.image -}}
{{- if $i.digest -}}
{{ printf "%s:%s@%s" $i.repository $i.tag $i.digest }}
{{- else -}}
{{ printf "%s:%s" $i.repository $i.tag }}
{{- end -}}
{{- end -}}

{{/*
  Same shape as ../disagg-pd/templates/_helpers.tpl's own disagg.engineArgs
  (call with (dict "root" $ "role" "prefill"|"decode")), minus the
  router-discovery annotation concern (this chart's sidecar reads the
  bootstrap port from its own value/env, not from a pod annotation).
*/}}
{{- define "disagg.engineArgs" -}}
{{- $v := .root.Values -}}
{{- $args := list "--disaggregation-mode" .role "--disaggregation-transfer-backend" (lower $v.transport.backend) -}}
{{- if eq .role "prefill" -}}
{{- $args = concat $args (list "--disaggregation-bootstrap-port" (toString $v.transport.bootstrapPort)) -}}
{{- end -}}
{{- /*
  Review round 3 (non-blocking, confirmed real): metrics.enabled
  rendered the scrape labels/annotations but never passed this flag, so
  SGLang would not have served /metrics at all -- ../disagg-pd's own
  disagg.engineArgs already sets it this way; this chart had dropped it by
  mistake when the helper was otherwise trimmed down for this chart's own
  routing differences.
*/}}
{{- if $v.metrics.enabled -}}
{{- $args = append $args "--enable-metrics" -}}
{{- end -}}
{{- $r := index $v .role -}}
{{- /*
  Real-hardware finding (g7.8xlarge, 2026-11-23): SGLang's own automatic
  --mem-fraction-static sizing does not reserve room for
  engine.stagingPoolSizeMb, and decode can OOM at startup on a small GPU --
  see decode.memFractionStatic's own values.yaml comment for the full
  story and the confirmed-working value. Empty (default): omit the flag,
  SGLang's own default, unchanged behavior.
*/}}
{{- if $r.memFractionStatic -}}
{{- $args = concat $args (list "--mem-fraction-static" (toString $r.memFractionStatic)) -}}
{{- end -}}
{{- $args = concat $args $r.extraArgs -}}
{{- $args | toJson -}}
{{- end -}}

{{/*
  Name of the InferencePool the router chart renders (same convention as
  ../../vllm/disagg-pd-llmd).
*/}}
{{- define "disagg.inferencePoolName" -}}
{{- .Release.Name -}}
{{- end -}}

{{/* Fail rendering on value combinations that would deploy something other than what they say. */}}
{{- define "disagg.validate" -}}
{{- $t := .Values.transport -}}
{{- if not (has $t.backend (list "NIXL" "MOONCAKE")) -}}
{{- fail (printf "transport.backend must be NIXL or MOONCAKE, got %q" $t.backend) -}}
{{- end -}}
{{- if and (eq $t.backend "NIXL") (not (has $t.sglangNixlBackend (list "LIBFABRIC" "UCX"))) -}}
{{- fail (printf "transport.sglangNixlBackend must be LIBFABRIC or UCX, got %q" $t.sglangNixlBackend) -}}
{{- end -}}
{{- if and (eq $t.backend "MOONCAKE") (not (has $t.mooncakeProtocol (list "efa" "tcp"))) -}}
{{- fail (printf "transport.mooncakeProtocol must be efa or tcp, got %q" $t.mooncakeProtocol) -}}
{{- end -}}
{{- if and (eq $t.backend "NIXL") (eq $t.sglangNixlBackend "UCX") -}}
{{- if not (regexMatch "^[1-9][0-9]{0,4}-[1-9][0-9]{0,4}$" $t.ucx.tcpPortRange) -}}
{{- fail (printf "transport.ucx.tcpPortRange must be \"<first>-<last>\" with plain decimal digits only (no leading zero), got %q" $t.ucx.tcpPortRange) -}}
{{- end -}}
{{- $ucxParts := splitList "-" $t.ucx.tcpPortRange -}}
{{- $ucxFirst := atoi (index $ucxParts 0) -}}
{{- $ucxLast := atoi (index $ucxParts 1) -}}
{{- if or (lt $ucxFirst 1) (gt $ucxLast 65535) (ge $ucxFirst $ucxLast) -}}
{{- fail (printf "transport.ucx.tcpPortRange=%q must satisfy 1 <= first < last <= 65535" $t.ucx.tcpPortRange) -}}
{{- end -}}
{{- if gt (sub (add $ucxLast 1) $ucxFirst) 4096 -}}
{{- fail (printf "transport.ucx.tcpPortRange=%q spans more than 4096 ports -- keep this narrow (never something like 1024-65535)" $t.ucx.tcpPortRange) -}}
{{- end -}}
{{- end -}}
{{- if and $t.forceEfaSameNode (not (and (eq $t.backend "NIXL") (eq $t.sglangNixlBackend "LIBFABRIC"))) -}}
{{- fail "transport.forceEfaSameNode is only defined for transport.backend=NIXL with sglangNixlBackend=LIBFABRIC (the only combination that sets FI_EFA_ENABLE_SHM_TRANSFER at all): with backend=MOONCAKE, whether Mooncake's EFA transport honors the same libfabric variable is unconfirmed (RFC #37, Decision 6); with sglangNixlBackend=UCX, no FI_EFA_* env is rendered at all, so the flag would silently do nothing rather than force anything onto EFA" -}}
{{- end -}}
{{- if and $t.forceEfaSameNode (not .Values.placement.sameNodeMeasurement) -}}
{{- fail "transport.forceEfaSameNode=true only makes sense with placement.sameNodeMeasurement=true; a cross-node run already uses the EFA device path" -}}
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
{{- if lt (int $r.efaDevices) 1 -}}
{{- fail (printf "%s.efaDevices must be at least 1: every transport combination this chart renders needs an EFA device (NIXL+LIBFABRIC, MOONCAKE+efa)" $role) -}}
{{- end -}}
{{- end -}}
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
{{- fail (printf "llmdRouter.router.modelServers.targetPorts must be exactly [engine.port] (%d), got %s: the EPP sends every request to that port, where a prefill pod's SGLang and a decode pod's routing sidecar listen" (int .Values.engine.port) (toJson $ports)) -}}
{{- end -}}
{{- if ne (toString $ms.type) "sglang" -}}
{{- fail (printf "llmdRouter.router.modelServers.type must be sglang for this chart, got %q" (toString $ms.type)) -}}
{{- end -}}
{{- if eq (int .Values.routingSidecar.enginePort) (int .Values.engine.port) -}}
{{- fail "routingSidecar.enginePort must differ from engine.port: on a decode pod the sidecar listens on engine.port and SGLang behind it on routingSidecar.enginePort" -}}
{{- end -}}
{{- if or (eq (int .Values.routingSidecar.metricsPort) (int .Values.engine.port)) (eq (int .Values.routingSidecar.metricsPort) (int .Values.routingSidecar.enginePort)) -}}
{{- fail "routingSidecar.metricsPort must differ from engine.port and routingSidecar.enginePort" -}}
{{- end -}}
{{- if ne (toString .Values.routingSidecar.kvConnector) "sglang" -}}
{{- fail (printf "routingSidecar.kvConnector must be sglang for this chart (llm-d-router v1.0.0's SGLang-specific connector), got %q" (toString .Values.routingSidecar.kvConnector)) -}}
{{- end -}}
{{- if ne (int .Values.routingSidecar.bootstrapPort) (int .Values.transport.bootstrapPort) -}}
{{- fail (printf "routingSidecar.bootstrapPort (%d) must equal transport.bootstrapPort (%d): the sidecar's SGLANG_BOOTSTRAP_PORT and the prefill engine's own --disaggregation-bootstrap-port must name the same port" (int .Values.routingSidecar.bootstrapPort) (int .Values.transport.bootstrapPort)) -}}
{{- end -}}
{{- if ne (toString .Values.llmdRouter.router.inferencePool.failureMode) "FailClose" -}}
{{- if ne (toString .Values.llmdRouter.router.inferencePool.failureMode) "FailOpen" -}}
{{- fail (printf "llmdRouter.router.inferencePool.failureMode must be FailClose or FailOpen, got %q" (toString .Values.llmdRouter.router.inferencePool.failureMode)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
