{{/*
capacity-pool.capacityTypeValues: the karpenter.sh/capacity-type values
list for pool.capacityType, as a JSON array. One release declares exactly
one capacity type (#17: reserved capacity never shares a NodePool with
spot or on-demand capacity), so there is no shape here that mixes
"reserved" with anything else.
*/}}
{{- define "capacity-pool.capacityTypeValues" -}}
{{- $ct := required "pool.capacityType is required (on-demand, reserved or flex)" .Values.pool.capacityType -}}
{{- if eq $ct "on-demand" -}}
{{- list "on-demand" | toJson -}}
{{- else if eq $ct "reserved" -}}
{{- list "reserved" | toJson -}}
{{- else if eq $ct "flex" -}}
{{- list "spot" "on-demand" | toJson -}}
{{- else -}}
{{- fail (printf "pool.capacityType must be one of on-demand, reserved, flex (got %q)" $ct) -}}
{{- end -}}
{{- end -}}

{{/*
capacity-pool.requirements: the NodePool's requirements list, as a JSON
array: the karpenter.sh/capacity-type entry generated from
pool.capacityType first, then pool.requirements as given. A
karpenter.sh/capacity-type entry inside pool.requirements is rejected, so
pool.capacityType stays the only place the capacity type is declared.
*/}}
{{- define "capacity-pool.requirements" -}}
{{- range .Values.pool.requirements -}}
{{- if eq .key "karpenter.sh/capacity-type" -}}
{{- fail "pool.requirements must not contain karpenter.sh/capacity-type; set pool.capacityType instead" -}}
{{- end -}}
{{- end -}}
{{- $ct := dict "key" "karpenter.sh/capacity-type" "operator" "In" "values" (include "capacity-pool.capacityTypeValues" . | fromJsonArray) -}}
{{- prepend .Values.pool.requirements $ct | toJson -}}
{{- end -}}
