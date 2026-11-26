# neuron-healthcheck (issue #97)

A cheap, standard pre-flight that runs before a Trainium (Neuron) verification
on this platform, so a bad node is caught before the real run starts, not
mid-measurement. It
is the Neuron counterpart of [`../gpu-healthcheck`](../gpu-healthcheck): the
same shape (a `run.sh` that renders one disposable Job onto one node, exits
non-zero on failure, and uses `kubectl logs` as its only result transport),
with three checks written for Neuron hardware.

**This is an example, not part of the platform.** It lives under
`examples/`, not `gitops/` (see [`../../../AGENTS.md`](../../../AGENTS.md)
section 3): nothing in `infra/foundation/` or `gitops/` depends on it, and
its own failure cannot break a cell.

## Why this tool exists, and what it does not duplicate

The only place this platform exercises a real Neuron device outside this
tool is inside the accelerator e2e extension of `gitops/tests/1.e2e.sh`
(`GITOPS_RUN_ACCEL_E2E=1`, issues
[#28](https://github.com/littlemex/distai-platform/issues/28)/[#87](https://github.com/littlemex/distai-platform/issues/87)),
whose `check_accel_layer1` Neuron probe runs `neuron-ls` in a pod and checks
it reports exactly one device. That is a real check, but it is reachable
only by running the whole accelerator e2e suite (30 minutes or more). This
tool lifts the same assertion out into a standalone pre-flight that runs by
itself and reaches `Complete` or `Failed` before `run.sh`'s own 20-minute
deadline (confirmed on real hardware, issue #97), and adds what that probe
does not check: the NeuronCore count, and a model actually loading and
running on the device.

It is also not a duplicate of issue
[#78](https://github.com/littlemex/distai-platform/issues/78)'s CPU-only
compile check (`.github/scripts/neuron_cpu_compile_check.py`, issue
[#79](https://github.com/littlemex/distai-platform/issues/79)). That check
compiles a tiny model to a NEFF on a GitHub-hosted runner with no Neuron
device (`cpu_backend=True`), which proves the compiler toolchain installs and
compiles. It cannot load the NEFF anywhere, and its own docstring says so.
This tool's check 1 compiles the same model shape on a real Trainium node and
then runs it on the device, which goes through the Neuron Runtime and so
proves the container's Neuron Runtime works with the node's Neuron driver.
An `nrt_init` ABI mismatch between the two is exactly the failure a
compile-only check cannot see.

## Why nothing is vendored

[`../gpu-healthcheck`](../gpu-healthcheck) adopts and vendors
`awslabs/awsome-distributed-ai`'s GPU health-check suite. There is no Neuron
equivalent to adopt. The OSS comparison table in issue
[#97](https://github.com/littlemex/distai-platform/issues/97)'s design comment
covers the candidates; in short:

- `awslabs/awsome-distributed-ai`'s `validation/gpu-cluster-healthcheck/` is
  NVIDIA-only end to end (`nvidia-smi`, DCGM, the Xid catalog) and has no
  Neuron counterpart anywhere in that repository.
- SageMaker HyperPod's health monitoring agent reads the same `neuron-ls`
  signal check 0 uses, but it is part of the SageMaker HyperPod control plane,
  not a standalone component, and needs a HyperPod-orchestrated cluster; this
  platform is plain EKS with Karpenter.
- The Neuron SDK's own tools (`neuron-ls`, `neuron-top`, `neuron-monitor`) are
  the building blocks this tool calls; no packaged pre-flight suite ships
  around them.
- `kubernetes/node-problem-detector` and the EKS node monitoring agent detect
  problems after the fact, the same objection
  [`../gpu-healthcheck/README.md`](../gpu-healthcheck/README.md) gives for the
  GPU case; they are not a pre-flight before a workload starts.

Everything under this directory is therefore written for this repository,
from first principles. Following `AGENTS.md` section 5 ("Separate what is
not"), it is a separate tool from `gpu-healthcheck`, not a vendor branch
inside it: `gpu-healthcheck`'s `vendor/` tree stays byte-for-byte upstream so
a re-pin is a clean diff, and Neuron logic mixed into it would break that.
Only the entry points are aligned: the same `run.sh` contract, the same
result transport, the same refusal rules.

## Instance profiles

`profiles/instance-profiles.conf` is this tool's own pipe-delimited table:

```text
INSTANCE_TYPE|DEVICE_COUNT|NEURONCORE_COUNT|EFA_COUNT
```

| Instance type | Neuron devices (source) | NeuronCores per device (source) | EFA interfaces (source) |
| --- | --- | --- | --- |
| `trn2.3xlarge` | 1 (measured, issue [#19](https://github.com/littlemex/distai-platform/issues/19) E4a/E4b) | 4 (measured, issue #19 E4a/E4b) | 1 (issue [#50](https://github.com/littlemex/distai-platform/issues/50) fixture, cross-checked) |

- **Neuron devices and NeuronCores** come from issue #19's E4a/E4b runs on a
  real `trn2.3xlarge` in `ap-southeast-4` (2026-11-18): the Neuron device
  plugin advertised `aws.amazon.com/neuron: 1` and
  `aws.amazon.com/neuroncore: 4`, and `neuron-ls` showed device 0 with 4
  cores. Karpenter's own instance-type data estimates
  `aws.amazon.com/neuroncore: 8` for this type; the same measurement shows
  that estimate is wrong for the node's default configuration, in which two
  physical cores are grouped into one logical NeuronCore. The table carries
  the measured 4, and check 0 reads the count from the real device for the
  same reason: an estimate is what this check exists to not trust.
- **EFA interfaces** come from
  `gitops/charts/capacity-pool/tools/fixtures/trn2.3xlarge.describe.json`, a
  real `aws ec2 describe-instance-types` response captured 2026-11-25 in
  `ap-southeast-4`: its `EfaInfo.MaximumEfaInterfaces` field is 1.
  `tests/0.static.sh` cross-checks this against
  `GROUND_TRUTH["trn2.3xlarge"] = (1, 1)` in
  `gitops/tests/check_nic_layout.py` as well, so a change to either source
  fails the static check.

The expected EFA count is the instance type's maximum. A pool that
deliberately attaches fewer EFA interfaces than the type supports always
reports a mismatch here by design: like `gpu-healthcheck`, this tool cannot
tell "attached fewer on purpose" from "attached the wrong number by mistake",
so it expects the maximum and treats anything else as a defect to confirm by
hand.

Only `trn2.3xlarge` is listed. A row is added only when every field has the
same kind of source (a real measurement or a committed fixture);
`trn2.48xlarge`, `trn1` and `inf2` are not listed because this repository has
no such measurement for them yet. `run.sh` refuses to start for an instance
type with no row.

## Base image

The Job runs the AWS Neuron PyTorch inference deep learning container
`public.ecr.aws/neuron/pytorch-inference-neuronx:2.9.0-neuronx-py312-sdk2.31.1-ubuntu24.04`,
pinned in `run.sh` by tag and digest
(`sha256:de98dc02a68765df5688d301134debbd677ccdc4fbd6873af34fafafcc3462ec`,
read from the `public.ecr.aws` registry on 2026-11-27). It started as a
candidate because it is on the Neuron SDK 2.31 release line, the same
release-line number as the Neuron driver 2.31.8.0 measured on this
platform's own Neuron node AMI
(`amazon-eks-node-al2023-x86_64-neuron-1.37-v20261112`) in issue #19 -- a
number match that this tool does not treat as proof of ABI compatibility by
itself (the Neuron SDK's own component versions do not always track the
release-line number; `.github/workflows/neuron-cpu-compile-check.yml`'s own
comment on this platform makes that same point about a different pair of
components). The real proof is empirical, from issue #97's own real-hardware
run: this exact image's `torch_neuronx` compiled a NEFF and then loaded and
ran it through the Neuron Runtime against this exact driver on a real
`trn2.3xlarge` node, with no ABI error (the versions the Job itself printed:
`aws-neuronx-runtime-lib 2.33.10.0-3dcef56f0`, `torch-neuronx 2.9.0.2.15.32035+de43f57c`,
against driver `2.31.8.0`). It is also the image
`.github/workflows/neuron-cpu-compile-check.yml` names as the container it
considered for #78/#79. It ships `torch`, `torch_neuronx`, the Neuron
compiler, the Neuron Runtime and `neuron-ls`, so the Job installs nothing for
checks 0 and 1. The image is about 7.5 GiB compressed -- the same figure
`.github/workflows/neuron-cpu-compile-check.yml`'s own comment already states
for this exact tag, measured against the `public.ecr.aws` registry on
2026-11-26, not re-measured here; the first run on a fresh node spends
minutes pulling it. When the node AMI moves to a different Neuron driver,
re-verify by running this tool against a real node rather than picking a new
`BASE_IMAGE` by release-line number alone -- the number was only ever a
starting point, confirmed in issue #97's own real-hardware run for this one
pairing, not a rule that holds for every future pairing.

Both real runs in issue #97's own Test Results reached `Complete`/`Failed`
(`run.sh`'s own log carries no "neither Complete nor Failed after 20m"
warning for either run) before `run.sh`'s own 20-minute deadline; the
pre-flight's own wall-clock time was not separately measured.

`BASE_IMAGE` overrides the default. When the node AMI moves to a new Neuron
driver line, pick a candidate image, re-read its digest from the registry
(on the EC2 runner, not the Mac), and confirm it with a real run of this
tool rather than by release-line number alone (see "Base image" above). The
Job's log records the host driver version (`/sys/module/neuron/version`)
and the container's Neuron package versions for a human to compare; the
tool does not assert an exact driver version, because the AMI moves.

## The three checks

The Job runs the checks in order and stops at the first failure: a node with
the wrong device count would only fail the later checks for the same reason.
`lib/aggregate-results.py` reports a check that never ran as `NOT_RUN`, which
fails the summary.

| # | Script | Proves | Fails when |
| --- | --- | --- | --- |
| 0 | `lib/checks/0-neuron-ls-check.sh` | The container sees the expected Neuron devices, each with the expected NeuronCore count | `neuron-ls --json-output` lists a different number of devices than `DEVICE_COUNT`, any device's `nc_count` differs from `NEURONCORE_COUNT`, the output cannot be parsed, or `neuron-ls` is missing |
| 1 | `lib/checks/1-neff-compile-load-check.py` | A NEFF compiles for `--target trn2`, and loads and runs on the device through the Neuron Runtime | `torch_neuronx.trace()` raises, writes no non-empty `.neff`, or running the traced model raises (including `nrt_init` and any other Neuron Runtime error), or the output is not shaped `(8, 10)` |
| 2 | `lib/checks/2-efa-enumeration-check.sh` | The node has the expected number of EFA PCI functions attached | `lspci \| grep -ci EFA` differs from `EFA_COUNT`, or `lspci` is unavailable and `pciutils` cannot be installed |

Check 0 uses the JSON-parsing rule of `gitops/tests/1.e2e.sh`'s
`check_accel_layer1` Neuron probe (accept a top-level list, or an object
wrapping exactly one list). Check 2 mirrors the PCI sub-check of upstream's
own check 2 (`../gpu-healthcheck/vendor/awsome-distributed-ai/checks/2-efa-enumeration.sh`),
which `../gpu-healthcheck/README.md` calls genuinely accelerator-agnostic; it
is written fresh here rather than imported across `examples/` subtrees. Like
upstream, a matching count with the `efa` kernel module not loaded is a
`WARN`, not a failure. No EFA installer runs: the PCI count does not need
libfabric userspace tools.

Each check writes `check-<name>.json` (`check`, `status`, `message`,
`evidence`, `node`, `instance_type`, `timestamp`; schema in
`lib/common.sh`), and `lib/aggregate-results.py` writes `summary.json`
(`PASS`, `WARN` or `FAIL` overall, one entry per check). The Job prints both,
so they appear in `kubectl logs`.

### Check 1 is a smoke test on one fixed model

Check 1's model is a fixed two-layer MLP (`d_in=128, d_hidden=256,
d_out=10`, input `torch.randn(8, 128)`), the same shape as
`.github/scripts/neuron_cpu_compile_check.py`'s `build_example_model()`. It is
defined again in this tool rather than imported, because each `examples/`
subtree is self-contained (`AGENTS.md` section 3); a comment next to this
tool's copy names the other file, so a change to one is noticed in the other. A pass means this exact model compiles,
loads and runs on this node with this image. It does not mean every operator
this platform's workloads use would compile. The output is checked for shape
only; its difference from the same model run on CPU is recorded in the
evidence, not asserted, because the compiler may lower fp32 matrix multiplies
to a narrower type by default.

## Deliberate deviations

There is no suite to adopt, so these are deviations from what a full
health-check deployment would look like, not from an upstream tree. They are
the same three `../gpu-healthcheck/README.md` states for its own Job, for the
same reasons:

1. **No custom container image.** Neither the Mac nor this platform's EC2
   runner builds container images. `run.sh` puts the five scripts in two
   `ConfigMap`s (`neuron-healthcheck-lib-root-<RUN_ID>` for `lib/common.sh`
   and `lib/aggregate-results.py`, `neuron-healthcheck-lib-checks-<RUN_ID>`
   for the three checks, `defaultMode: 0755`) and mounts them into the
   public, pre-built Neuron DLC above. The only install at run time is
   `pciutils`, and only if `lspci` is missing from the image.
2. **A single Job targeting one node, not a cluster-wide DaemonSet.** The
   purpose is a pre-flight for the node a Neuron verification is about to use,
   run on demand. `INSTANCE_TYPE` selects by `node.kubernetes.io/instance-type`,
   which can match more than one node of the same type; it does not pin a
   `kubernetes.io/hostname`. Run this against a cell that has only one node
   of the type under test, or add a `kubernetes.io/hostname` selector by hand,
   until a per-node-name input is added.
3. **The Job requests no `aws.amazon.com/neuron` or
   `aws.amazon.com/neuroncore`.** It reaches `/dev/neuron*` directly, through
   a privileged container with the host's `/dev` mounted and `hostPID`, the
   same posture upstream's GPU DaemonSet documents ("does NOT request
   `nvidia.com/gpu`... accesses GPUs via device files in privileged mode"), so
   the pre-flight never consumes a device-plugin slot a real workload would
   otherwise get. The consequence follows from the manifest alone, not from a
   run against a real Kueue (the `QUEUE_NAME` path was not exercised in
   issue #97's own real-hardware run, only the unsuspended, no-Kueue path
   was): a `ClusterQueue` quota can only count what a Job actually requests,
   and this Job requests no accelerator resource, so it is expected to be
   admitted on CPU and memory alone, reserving no device. Run the pre-flight
   before scheduling the real verification workload on that node, not
   alongside it; check 1 is expected to fail if another process already
   holds the NeuronCores (the Neuron Runtime's own exclusive-access
   behavior). Neither expectation in this paragraph was verified by a real
   run in issue #97; both follow from the manifest and from Kueue's and the
   Neuron Runtime's own documented behavior.

The Job has no `hostNetwork`: none of the checks needs the host's network
namespace. It tolerates the `aws.amazon.com/neuron` `NoSchedule` taint.

## Running it

Prerequisites: `kubectl` pointing at the target cluster (this script never
changes the context), permission to create a namespace, `ConfigMap`s and a
`Job`, and a `trn2.3xlarge` node (or a Karpenter pool that can provision one
for the Job's `nodeSelector`).

```bash
export KUBECONFIG=/path/to/the/target/cluster/kubeconfig
export INSTANCE_TYPE=trn2.3xlarge
examples/tools/neuron-healthcheck/run.sh
```

With Kueue installed and a `LocalQueue` named `smoke` in the
`neuron-healthcheck` namespace, bind the Job to it instead of running
unsuspended:

```bash
export QUEUE_NAME=smoke
examples/tools/neuron-healthcheck/run.sh
```

To prove the deliberate-failure path (the Test Plan step for this tool, never
for a real pre-flight), render the profile with `trn2.3xlarge`'s
`DEVICE_COUNT` off by one (1 becomes 2), so check 0 must fail on correct
hardware:

```bash
export INJECT_BAD_DEVICE_COUNT=1
examples/tools/neuron-healthcheck/run.sh
```

That run is expected to exit non-zero, with check 0 `FAIL` and checks 1 and 2
`NOT_RUN` in `summary.json`.

Other optional variables: `NAMESPACE` (default `neuron-healthcheck`),
`BASE_IMAGE` (see "Base image"), `RUN_ID` (default `date +%s`; must be unique
per concurrent run, since the Job and `ConfigMap` names carry it), `KUBECTL`
(default `kubectl`).

`run.sh` refuses to start, before creating anything, when `INSTANCE_TYPE`
does not have exactly one row in the profile table, when
`INJECT_BAD_DEVICE_COUNT=1` did not actually change anything, when
`RUN_ID`/`NAMESPACE`/`QUEUE_NAME` is not a DNS-1123 label, or when a Job with
the same `RUN_ID` already exists (re-applying a finished Job runs nothing new
and would report the old result). It then polls the Job's
`status.conditions` (not `kubectl wait --for=condition=complete`, which never
returns for a Job that reaches `Failed`) and exits non-zero when the Job
reaches `Failed`, or has reached neither `Complete` nor `Failed` after 20
minutes (not admitted, stuck `Pending`, still pulling the image, or still
running). It prints the Pod's logs, which carry `summary.json` and every
per-check result, and deletes both `ConfigMap`s whether the run passed or
failed. The Job itself is removed by `ttlSecondsAfterFinished: 3600`.

Static checks (no cluster, no device), run on the EC2 runner:

```bash
bash examples/tools/neuron-healthcheck/tests/0.static.sh
```

## Known limitations

- Only `trn2.3xlarge` has a profile row (see "Instance profiles").
- Check 1 is a toolchain smoke test on one fixed tiny model (see above). It
  compiles for `--target trn2` only, which matches the one profiled type.
- The tool does not check that `/dev/neuron*` is allocated to the right pod
  by the device plugin; it bypasses the device plugin on purpose (deviation
  3). The device-plugin path is covered by the accelerator e2e extension of
  `gitops/tests/1.e2e.sh`.
- No NeuronCore-to-NeuronCore or inter-node collective check, the same way
  `gpu-healthcheck` keeps multi-node NCCL out of its lightweight suite.
- The 20-minute deadline includes node provisioning and the image pull. On a
  cold spot node both can take several minutes; a timeout reads as `FAIL`
  with a warning naming the Job's last condition. If `run.sh` times out while
  the Pod has not started yet, deleting the `ConfigMap`s leaves that Pod
  unable to start; delete the Job by hand
  (`kubectl delete job -n neuron-healthcheck neuron-healthcheck-preflight-$RUN_ID`).
- Check 2 installs `pciutils` with `apt-get` only if `lspci` is missing from
  the image, which needs egress to the Ubuntu package mirrors from the Pod.
  Without egress, and without `lspci` in the image, check 2 fails with a
  message saying the EFA count could not be read.
