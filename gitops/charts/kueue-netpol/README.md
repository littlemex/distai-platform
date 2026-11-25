# kueue-netpol

A `NetworkPolicy` for Kueue's own `controller-manager` Pod (#63, filed as
"SA4"). Before this chart, nothing restricted traffic to that Pod at all -
any Pod in any namespace could reach every port it listens on, including
the port that decides what Kueue admits.

Allows ingress on exactly three ports, each with no `from:` peer selector
(kube-apiserver and the node's own kubelet cannot be matched by a
`podSelector`/`namespaceSelector` the way an ordinary Pod can - the same
reasoning upstream Kueue's own Kustomize `NetworkPolicy` component
documents, `kubernetes-sigs/kueue`
`config/components/networkpolicy/manager-ingress.yaml`):

| Port | What reaches it |
| --- | --- |
| `9443` | kube-apiserver, the admission webhook |
| `8082` | kube-apiserver, the aggregated visibility API |
| `8081` | kubelet on this Pod's own node, the liveness/readiness probe |

Everything else is denied, including the metrics port (`8443`, fronted by
`kube-rbac-proxy`): no Prometheus Operator CRDs or scraper exist in a cell
yet (`gitops/addons/kueue/addon.yaml`'s own comment), so nothing needs it
open today.

## Values

| Key | Required | Description |
| --- | --- | --- |
| `namespace` | yes | Must equal `gitops/addons/kueue/addon.yaml`'s own `namespace:` field |
| `podSelector` | yes | Label map matching the pinned chart's own `controller-manager` Pod; default matches Kueue `0.20.6` |

Not a wrapper around Kueue's own chart: that chart ships no `NetworkPolicy`
template at this pinned version (confirmed by pulling and inspecting it,
2026-11-23), so this is a second, independent `Application` in the same
`controllers` wave, delivered by `gitops/addons/kueue-netpol/addon.yaml`.
A version bump of `gitops/addons/kueue/addon.yaml` that changes the
controller-manager Pod's own labels or ports needs a reviewed diff here
too - nothing mechanically keeps the two in sync.
