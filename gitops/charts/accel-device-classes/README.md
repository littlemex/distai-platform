# accel-device-classes

The platform's own DRA `DeviceClass` catalog
([#19](https://github.com/littlemex/distai-platform/issues/19) Decision 1(c),
[#28](https://github.com/littlemex/distai-platform/issues/28) section B). It
renders exactly one object:

| Kind | Name | Selector | `extendedResourceName` |
| --- | --- | --- | --- |
| `DeviceClass` (`resource.k8s.io/v1`) | `neuron-extended-resource` | `device.driver == "neuron.aws.com"` | `aws.amazon.com/neuron` |

The Neuron DRA driver chart (`gitops/addons/accel-neuron-dra/addon.yaml`)
ships its own `DeviceClass` `neuron.aws.com` without an
`extendedResourceName`, so a pod that requests `aws.amazon.com/neuron`
through `resources.limits` (a Layer 1 request) is not scheduled onto a node
whose Neuron devices are published only through DRA. This chart adds that
mapping. NVIDIA needs no entry here: its DRA chart already ships
`gpu.nvidia.com` with `extendedResourceName: nvidia.com/gpu`.

## Delivery

Delivered by `gitops/appsets/platform.ApplicationSet.yaml` from
`gitops/addons/accel-device-classes/addon.yaml`
(`dir: gitops/charts/accel-device-classes`, step `accelerators`), once per
cell.
This chart is never installed from an upstream chart registry.

## Values

None. Nothing in this chart varies per cell; `values.yaml` is empty and
exists only so that every chart under `gitops/charts/` has the same shape.

## Prerequisites

- Kubernetes with the `resource.k8s.io/v1` API and the DRA extended
  resource feature (`DeviceClass.spec.extendedResourceName`) enabled.
- On a cell where no node runs the Neuron DRA driver, the `DeviceClass`
  exists and matches no device; it costs nothing.

## Known limits

- One `DeviceClass` only. Adding another accelerator's mapping is a new
  template in this chart, not a new chart.
