# karpenter-netpol

A `NetworkPolicy` for Karpenter's own controller Pod (#63, filed as
"SA4"). Before this chart, any Pod in any namespace could reach every
port it listens on.

At this pinned version (`1.15.2`) that is only metrics (`8080`) and the
health probe (`8081`) - no webhook port exists (older Karpenter releases
shipped a knative-style webhook server; the chart no longer does,
confirmed by rendering it).

| Port | What reaches it |
| --- | --- |
| `8081` | kubelet on this Pod's own node, the liveness/readiness probe (no `from:` peer selector - the node itself cannot be matched by one, the same reasoning `kueue-netpol` uses for its own probe port) |

Everything else is denied, including metrics (`8080`): no Prometheus
Operator CRDs or scraper exist in a cell yet - narrow it to a real
scraper's identity once one does, rather than opening it to every Pod in
the meantime.

## Values

| Key | Required | Description |
| --- | --- | --- |
| `namespace` | yes | Must equal `gitops/addons/karpenter/addon.yaml`'s own `namespace:` field |
| `podSelector` | yes | Label map matching the pinned chart's own controller Pod; default matches Karpenter `1.15.2` |

Not a wrapper around Karpenter's own chart: a second, independent
`Application` in the same `controllers` wave, delivered by
`gitops/addons/karpenter-netpol/addon.yaml`. A version bump of
`gitops/addons/karpenter/addon.yaml` that reintroduces a webhook port (or
changes the controller Pod's own labels) needs a reviewed diff here too.
