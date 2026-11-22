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

{{/*
capacity-pool.taints: every NodePool taint this release declares, as a
JSON array of {key, value, effect}. accelerator.taint and
tenancy.teamTaint both feed this one list; an entry whose key is empty is
skipped. nodepool.yaml renders the list as NodePool taints and
resourceflavor.yaml mirrors the same list as ResourceFlavor tolerations,
so the two can never disagree.
*/}}
{{- define "capacity-pool.taints" -}}
{{- $sources := list
      (dict "name" "accelerator.taint" "taint" (default (dict) (default (dict) .Values.accelerator).taint))
      (dict "name" "tenancy.teamTaint" "taint" (default (dict) (default (dict) .Values.tenancy).teamTaint)) -}}
{{- $out := list -}}
{{- $seen := dict -}}
{{- range $sources -}}
{{- $t := .taint -}}
{{- if $t.key -}}
{{- if not (has $t.effect (list "NoSchedule" "PreferNoSchedule" "NoExecute")) -}}
{{- fail (printf "%s.effect must be one of NoSchedule, PreferNoSchedule, NoExecute (got %q)" .name (toString $t.effect)) -}}
{{- end -}}
{{- /*
#22 Decision 3 accepts a team-exclusive toleration only with a value
equal to the team's own label, never a bare "operator: Exists" (#63,
filed as #56): an empty tenancy.teamTaint.value would otherwise render
exactly that (the entry below only sets "value" when $t.value is
truthy), making a "team-exclusive" pool soft - any pod tolerating the
bare key, from any team, gets in. accelerator.taint has no such rule
(an accelerator-class toleration without a specific value is the
intended shape there: any pod requesting the device, from whichever
team, may use it), so this check is scoped to tenancy.teamTaint only.
*/}}
{{- if and (eq .name "tenancy.teamTaint") (not $t.value) -}}
{{- fail "tenancy.teamTaint.value is required when tenancy.teamTaint.key is set (#22 Decision 3: a team-exclusive taint must name the team, never a bare operator: Exists)" -}}
{{- end -}}
{{- $id := printf "%s:%s" $t.key $t.effect -}}
{{- if hasKey $seen $id -}}
{{- fail (printf "%s repeats the taint key %q with effect %s already set by %s" .name $t.key $t.effect (get $seen $id)) -}}
{{- end -}}
{{- $_ := set $seen $id .name -}}
{{- $entry := dict "key" $t.key "effect" $t.effect -}}
{{- if $t.value -}}
{{- $_ := set $entry "value" (toString $t.value) -}}
{{- end -}}
{{- $out = append $out $entry -}}
{{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/*
capacity-pool.annotations: the metadata.annotations block shared by the
NodePool and the ResourceFlavor. Provenance only: no template branches on
accelerator.resourceName's value. Renders nothing when it is empty.
*/}}
{{- define "capacity-pool.annotations" -}}
{{- $name := (default (dict) .Values.accelerator).resourceName -}}
{{- if $name -}}
annotations:
  distai.dev/accelerator-resource-name: {{ $name | quote }}
{{- end -}}
{{- end -}}
