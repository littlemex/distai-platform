{{/*
optional-pool.capacityTypeValues / optional-pool.requirements: the same
shape gitops/charts/capacity-pool/templates/_helpers.tpl already uses for
its own pool.capacityType/pool.requirements (#63, filed as #58 Option A -
the two charts previously disagreed on where the capacity type lives:
capacity-pool nests everything under pool.*, optional-pool had a
top-level requirements: key and no capacityType field of its own at
all, with on-demand hardcoded directly into values.yaml's own
requirements list instead). optional-pool only ever uses "on-demand"
today (RFC #41: an admin component should not be evicted by a Spot
interruption), but takes the same pool.capacityType field and the same
validation rather than a chart-specific shortcut, so a reader who has
learned one chart's values shape does not get the other chart's rule
silently ignored.
*/}}
{{- define "optional-pool.capacityTypeValues" -}}
{{- $ct := required "pool.capacityType is required (on-demand)" .Values.pool.capacityType -}}
{{- if eq $ct "on-demand" -}}
{{- list "on-demand" | toJson -}}
{{- else -}}
{{- fail (printf "pool.capacityType must be \"on-demand\" (optional-pool is admin-owned, untainted capacity - never spot or reserved); got %q" $ct) -}}
{{- end -}}
{{- end -}}

{{- define "optional-pool.requirements" -}}
{{- range .Values.pool.requirements -}}
{{- if eq .key "karpenter.sh/capacity-type" -}}
{{- fail "pool.requirements must not contain karpenter.sh/capacity-type; set pool.capacityType instead" -}}
{{- end -}}
{{- end -}}
{{- $ct := dict "key" "karpenter.sh/capacity-type" "operator" "In" "values" (include "optional-pool.capacityTypeValues" . | fromJsonArray) -}}
{{- prepend .Values.pool.requirements $ct | toJson -}}
{{- end -}}
