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

{{/* true when the KV transfer this release is configured for runs over EFA. */}}
{{- define "disagg.efaTransport" -}}
{{- $t := .Values.transport -}}
{{- if or (and (eq $t.backend "NIXL") (eq $t.sglangNixlBackend "LIBFABRIC")) (and (eq $t.backend "MOONCAKE") (eq $t.mooncakeProtocol "efa")) -}}
true
{{- end -}}
{{- end -}}

{{/* Fail rendering on value combinations that would deploy something other than what they say. */}}
{{- define "disagg.validate" -}}
{{- $t := .Values.transport -}}
{{- if not (has $t.backend (list "NIXL" "MOONCAKE")) -}}
{{- fail (printf "transport.backend must be NIXL or MOONCAKE, got %q" $t.backend) -}}
{{- end -}}
{{- if not (has $t.sglangNixlBackend (list "LIBFABRIC" "UCX")) -}}
{{- fail (printf "transport.sglangNixlBackend must be LIBFABRIC or UCX, got %q" $t.sglangNixlBackend) -}}
{{- end -}}
{{- if not (has $t.mooncakeProtocol (list "efa" "tcp")) -}}
{{- fail (printf "transport.mooncakeProtocol must be efa or tcp, got %q" $t.mooncakeProtocol) -}}
{{- end -}}
{{- if and $t.forceEfaSameNode (eq $t.backend "MOONCAKE") -}}
{{- fail "transport.forceEfaSameNode=true is not defined for transport.backend=MOONCAKE: whether Mooncake's EFA transport honors FI_EFA_ENABLE_SHM_TRANSFER is unconfirmed (RFC #37, Decision 6)" -}}
{{- end -}}
{{- if and $t.forceEfaSameNode (ne $t.sglangNixlBackend "LIBFABRIC") -}}
{{- fail "transport.forceEfaSameNode=true only has an effect with transport.sglangNixlBackend=LIBFABRIC" -}}
{{- end -}}
{{- if and $t.forceEfaSameNode (not .Values.placement.sameNodeMeasurement) -}}
{{- fail "transport.forceEfaSameNode=true only makes sense with placement.sameNodeMeasurement=true; a cross-node run already uses the EFA device path" -}}
{{- end -}}
{{- if not .Values.placement.nodeSelectorKey -}}
{{- fail "placement.nodeSelectorKey must not be empty" -}}
{{- end -}}
{{- $efa := include "disagg.efaTransport" . -}}
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
{{- if and $efa (lt (int $r.efaDevices) 1) -}}
{{- fail (printf "%s.efaDevices must be at least 1 with an EFA transport (transport.backend=NIXL with sglangNixlBackend=LIBFABRIC, or MOONCAKE with mooncakeProtocol=efa)" $role) -}}
{{- end -}}
{{- end -}}
{{- $kvt := .Values.kvCacheTier -}}
{{- if not (has $kvt.mode (list "gpu-only" "local" "remote")) -}}
{{- fail (printf "kvCacheTier.mode must be gpu-only, local or remote, got %q" $kvt.mode) -}}
{{- end -}}
{{- if eq $kvt.mode "remote" -}}
{{- fail "kvCacheTier.mode=remote is not available for SGLang: its HiCache documents no Redis/ElastiCache backend, so this tier is vLLM-only (RFC #37, Decision 11). Use gpu-only or local" -}}
{{- end -}}
{{- if and (eq $kvt.mode "local") (lt (int $kvt.hicache.sizeGb) 1) -}}
{{- fail "kvCacheTier.mode=local requires kvCacheTier.hicache.sizeGb (the host KV pool per prefill engine, --hicache-size), sized to fit inside prefill.resources.requests.memory" -}}
{{- end -}}
{{- if not (has .Values.router.prefillPolicy (list "random" "round_robin" "cache_aware" "power_of_two" "prefix_hash")) -}}
{{- fail (printf "router.prefillPolicy must be random, round_robin, cache_aware, power_of_two or prefix_hash, got %q" .Values.router.prefillPolicy) -}}
{{- end -}}
{{- if not (has .Values.router.decodePolicy (list "random" "round_robin" "cache_aware" "power_of_two" "prefix_hash")) -}}
{{- fail (printf "router.decodePolicy must be random, round_robin, cache_aware, power_of_two or prefix_hash, got %q" .Values.router.decodePolicy) -}}
{{- end -}}
{{- end -}}

{{/* SGLang server flags this chart sets for one role, before <role>.extraArgs. Call with (dict "root" $ "role" "prefill"). */}}
{{- define "disagg.engineArgs" -}}
{{- $v := .root.Values -}}
{{- $r := index $v .role -}}
{{- $args := list "--disaggregation-mode" .role "--disaggregation-transfer-backend" (lower $v.transport.backend) -}}
{{- if eq .role "prefill" -}}
{{- $args = concat $args (list "--disaggregation-bootstrap-port" (toString $v.transport.bootstrapPort)) -}}
{{- end -}}
{{- if $v.metrics.enabled -}}
{{- $args = append $args "--enable-metrics" -}}
{{- end -}}
{{- if and (eq .role "prefill") (eq $v.kvCacheTier.mode "local") -}}
{{- $args = concat $args (list "--enable-hierarchical-cache" "--hicache-size" (toString $v.kvCacheTier.hicache.sizeGb)) $v.kvCacheTier.hicache.extraArgs -}}
{{- end -}}
{{- toJson (concat $args $r.extraArgs) -}}
{{- end -}}
