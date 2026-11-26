# gpu-healthcheck (issue #30)

A cheap, standard pre-flight that runs before every GPU-tier verification on
this platform, so a bad node is caught in minutes, not mid-measurement. This
adopts [`awslabs/awsome-distributed-ai`](https://github.com/awslabs/awsome-distributed-ai)'s
`validation/gpu-cluster-healthcheck/` suite directly and vendors it at a
pinned commit; it does not reimplement any check.

**This is an example, not part of the platform.** It lives under
`examples/`, not `gitops/` (see [`../../../AGENTS.md`](../../../AGENTS.md)
section 3): nothing in `infra/foundation/` or `gitops/` depends on it, and
its own failure cannot break a cell.

## Why adopt instead of reimplement

See issue [#30](https://github.com/littlemex/distai-platform/issues/30) for
the full OSS comparison table. In short: upstream's suite already supports
every GPU instance type this platform onboards except `g6e`, is maintained
in the same upstream org this platform already follows for every other
GPU-general convention (`AGENTS.md` section 5's "Upstream-ready Neuron
parts" principle runs the other direction here too — GPU-general content
belongs upstream, not reinvented here), and its severity model is already
aligned to NVIDIA's own Xid error catalog. The three real alternatives
(`node-problem-detector`, Karpenter/EKS node-monitoring-agent, bare
`nvidia-smi`/DCGM/EFA binaries) each either operate at the wrong layer
(detect-after-the-fact, not before a workload starts) or are the engine
*inside* this suite already, not a substitute for it.

## What is vendored, and the deviations from it

`vendor/awsome-distributed-ai/` is upstream's own
`validation/gpu-cluster-healthcheck/` tree, byte-for-byte, pinned at the
commit recorded in `vendor/VENDORED_COMMIT`, minus `slurm/` (this platform
is Kubernetes-only, see `AGENTS.md` section 3; the Slurm integration is
dead weight here). Do not hand-edit anything under `vendor/`; a future
re-pin re-copies the tree from a newer upstream commit so the diff a
reviewer sees is always "what upstream changed." `tests/0.static.sh` checks
this with `vendor/SHA256SUMS` (generated when the tree was vendored, not
derived from any logic this PR also wrote), not only a shebang grep.

This PR makes three deliberate deviations from upstream's own Kubernetes
deployment, each stated here, not left implicit:

1. **No custom container image.** Upstream's own `kubernetes/Dockerfile`
   builds a custom image
   (`YOUR_REGISTRY/gpu-healthcheck:latest # Replace with your image` —
   upstream ships no pre-built image of its own either). Neither the Mac
   nor this platform's EC2 runner can build and push a container image
   (standing tooling rule: no `docker`/`finch` builds off the Mac; the
   runner's own pinned toolchain has no image builder). `run.sh`
   substitutes a `ConfigMap` (the vendored scripts, read-only,
   `defaultMode: 0755`) mounted into upstream's own public, pre-built base
   image (`nvcr.io/nvidia/cloud-native/dcgm:3.3.7-1-ubuntu22.04`, the exact
   `FROM` upstream's `Dockerfile` already uses), and a startup step installs
   the same small userspace tools upstream's `Dockerfile` installs at build
   time (`pciutils`, EFA userspace libraries via `efa_installer.sh
   --skip-kmod`). No check script's own logic changed; only *when* and *how*
   the scripts reach the node changed.
2. **A single Job targeting one node, not a cluster-wide DaemonSet.**
   Upstream's own Kubernetes deployment is a DaemonSet that continuously
   checks every GPU node. This tool's own purpose (issue #30) is narrower: a
   pre-flight for the one node a GPU-tier verification is about to use, run
   on demand, not continuously. `INSTANCE_TYPE` selects by
   `node.kubernetes.io/instance-type`, which can match more than one node
   with the same type; it does not pin a specific `kubernetes.io/hostname`.
   Run this against a cell that has only one node of the type under test,
   or add a `nodeSelector`/`kubernetes.io/hostname` override by hand, until
   a per-node-name input is added.
3. **The Job requests no `nvidia.com/gpu`.** This mirrors upstream's own
   DaemonSet comment verbatim ("does NOT request `nvidia.com/gpu`... accesses
   GPUs via device files in privileged mode"), so the pre-flight never
   consumes a device-plugin slot a real workload would otherwise get. The
   consequence is Kueue's own `ClusterQueue` quota (when `QUEUE_NAME` is set)
   admits the Job on CPU/memory alone — it does not reserve the GPU and so
   does not stop a concurrent GPU workload from landing on the same node
   while the pre-flight runs. Run the pre-flight before scheduling the real
   verification workload on the same node, not alongside it.

## Pinning the base image

`run.sh`'s default `BASE_IMAGE` is a tag, not yet a digest, because this
platform has not yet confirmed one stable digest for this tag across every
Region/account this tool might run from (the same open question
`gitops/addons/accel-efa-device-plugin-nvidia/addon.yaml` already resolved
for its own ECR-hosted image, but `nvcr.io` is a different registry this
platform has not yet cross-checked the same way). Pin it with
`crane digest "${BASE_IMAGE}"` (run on the EC2 runner, never the Mac) before
a routine, unattended pre-flight; the pull request's own `## Test Results`
records the digest this PR's real run actually used.

## Instance profiles: extended, not re-derived

`profiles/g6e-overlay.conf` adds `g6e.12xlarge`/`g6e.48xlarge` rows upstream
does not have. The EFA and ENA device counts trace to this repository's own
measured source — issue [#50](https://github.com/littlemex/distai-platform/issues/50)'s
`gitops/charts/capacity-pool/tools/` generator and its committed
`fixtures/*.describe.json` (a real `aws ec2 describe-instance-types`
response, captured once, by hand): EFA count is the fixture's own
`EfaInfo.MaximumEfaInterfaces` field, cross-checked against
`gitops/tests/check_nic_layout.py`'s own `GROUND_TRUTH` table by
`tests/0.static.sh`; ENA count is inferred from the same fixture (only
network card 0 carries the primary `interface` entry in both types'
`*.networkInterfaces.yaml`), not a separately measured field. GPU count and
the absence of NVLink are AWS's own published instance-type specification
(a doc page), not re-derived from the fixture, which carries no GPU
information at all. See the comment header in `profiles/g6e-overlay.conf`
for exactly which source backs which field.

| Instance type | GPUs (source) | EFA devices (source) | ENA devices (source) | NVLink (source) |
| --- | --- | --- | --- | --- |
| `g6e.12xlarge` | 4x L40S (official spec) | 1 (measured, #50 fixture) | 1 (inferred, #50 fixture) | No (official spec) |
| `g6e.48xlarge` | 8x L40S (official spec) | 4 (measured, #50 fixture) | 1 (inferred, #50 fixture) | No (official spec) |
| `p4d.24xlarge` (reference) | 8x A100 (upstream's own table) | 4 (upstream's own table, cross-checked against #50's `GROUND_TRUTH`) | 1 | Yes |

The expected EFA count above is the instance type's maximum
(`MaximumEfaInterfaces`); a pool that deliberately attaches fewer EFA
interfaces than the type supports will always report a mismatch here by
design — this tool has no way to distinguish "attached fewer on purpose"
from "attached the wrong number by mistake," the exact ambiguity issue #30
opens with, so it always expects the maximum and treats anything else as a
defect to confirm by hand.

### NCCL bandwidth is out of scope for this pre-flight

Upstream's own check 5 (multi-node NCCL `all_reduce_perf`) and check 6 (EFA
loopback) are part of its *intensive* suite (45 min-2.25 hr, exclusive-node
access) — this tool runs only the *lightweight* suite (checks 0-3,
nvidia-smi/DCGM-L2/EFA-enumeration/topology, ~15 minutes), the same scoping
decision issue #30's own design states. `run.sh` does not run check 5 and
reports no NCCL bandwidth number; a g6e NCCL floor would not help that suite
regardless, since upstream's own `get_min_bus_bw()` and its NVLink-isolation
threshold table have no `g6e` row and L40S carries no NVLink fabric to
isolate. A future PR that wires the intensive suite into a manual quarantine
workflow (upstream's own `kubectl cordon` + Job-template pattern, unchanged)
is where that number would actually get produced.

### Neuron is out of scope for this PR, on purpose (AGENTS.md section 5)

Upstream's suite is NVIDIA-specific end to end: `nvidia-smi`, DCGM and the
NVIDIA Xid catalog have no Neuron equivalent (Neuron's own tooling is
`neuron-ls`/`neuron-monitor`, a different mechanism entirely). Per
`AGENTS.md` section 5 ("Separate what is not"), performance metrics and
profilers keep their own per-accelerator implementation; a Neuron-specific
pre-flight is explicitly not built here and would need its own vendored or
written tool. The one part of this suite that is genuinely
accelerator-agnostic is check 2's PCI-level EFA enumeration (`lspci | grep
-ci EFA`) — EFA network interfaces are not an NVIDIA concept, and the same
command would in principle also catch a `deviceIndex` mistake on a Neuron
node. This PR does not exercise it on Neuron hardware and does not split it
out as a standalone check; doing so is a reasonable, scoped follow-up, not
part of this PR's own acceptance criteria.

## Running it

```bash
export KUBECONFIG=/path/to/the/target/cluster/kubeconfig
export INSTANCE_TYPE=g6e.12xlarge
examples/tools/gpu-healthcheck/run.sh
```

With Kueue installed and a `LocalQueue` named `smoke` in the `gpu-healthcheck`
namespace, bind the Job to it instead of running unsuspended:

```bash
export QUEUE_NAME=smoke
examples/tools/gpu-healthcheck/run.sh
```

To prove the deliberate-failure path (this PR's own Test Plan step, never
for a real pre-flight):

```bash
export INJECT_BAD_EFA_COUNT=1
examples/tools/gpu-healthcheck/run.sh   # expected to exit non-zero
```

`run.sh` polls the Job's own `status.conditions` (not just `kubectl wait
--for=condition=complete`, which never returns for a Job that reaches
`Failed`) and exits non-zero when the Job reaches `Failed`, or has reached
neither `Complete` nor `Failed` after 20 minutes (not admitted, stuck
`Pending`, or still running past the timeout). `kubectl logs` of the Job's
one Pod carries `summary.json` and every per-check JSON result, which is
this tool's result transport — there is no separate dashboard or database.
`run.sh` also refuses to start, before creating anything, if
`INSTANCE_TYPE` has no exactly-one matching row in the merged
`instance-profiles.conf` (a silent PASS with an empty expectation is worse
than a refusal), and refuses `INJECT_BAD_EFA_COUNT=1` if nothing was
actually injected for that type.

## 2-node status (not yet confirmed on real hardware)

`manifests/job-2node.yaml.tmpl` is a reviewed design for the inter-node
EFA/NCCL check (two Pods, `podAntiAffinity` one per node, a headless
`Service` for rank discovery, upstream's own `all_reduce_perf` binary from
the official `public.ecr.aws/hpc-cloud/nccl-tests` image) — upstream's own
Kubernetes deployment has no multi-node NCCL job at all (its check 5 is
Slurm-`salloc`-only), so this is integration glue for an existing check, not
a new one. As of this PR it has not been run on real two-node hardware,
and the container's own logic to run upstream's `all_reduce_perf` over
`mpirun`/SSH between the two Pods has not been written yet either (it only
confirms both Pods schedule and exits 1 with a clear "not implemented"
message, see the comment in the template itself) -- a second instance was
not even requested this round, let alone found unavailable; this PR's own
single-node verification (see the pull request's own Test Results) was the
time-boxed scope. Treat it as a template to finish and
verify in a follow-up, not a proven mechanism.

## Known limitations

- The EFA kernel module itself (not just the userspace libraries this
  tool's Job installs) must already be loaded on the node. This platform's
  own `gitops/charts/capacity-pool` chart does not yet bootstrap it (no
  `userData`/`amiFamily` EFA installer step exists anywhere in `gitops/` or
  `infra/` today). Upstream's own check 2 treats a missing `fi_info`/
  `ibv_devices` as a soft WARN, not a failure — its own PCI/RDMA/uverbs-node
  sub-checks do not depend on the kernel module or on `fi_info`'s own
  availability, and can PASS without either (confirmed on real hardware,
  this PR's own Test Results: check 2 PASSed before the `PATH` fix in
  `## Changes` landed, with `fi_info` genuinely absent). The job template's
  own `[INFO]`/`[WARN]` lines after the installer step, and this tool's
  result transport (`kubectl logs`), are the only way to know whether
  `fi_info` was actually exercised in a given run; a `Complete` Job alone
  does not say. The PCI enumeration sub-check (`lspci | grep -ci EFA`),
  which is the one that catches the real incident this issue opens with (a
  `deviceIndex` mistake attaching the wrong number of interfaces), does not
  depend on the kernel module and still runs correctly either way.
- `dcgmi diag -r 2` (check 1) needs the NVIDIA driver visible to the
  container; this relies on the same privileged `hostPID`/`/dev` mount
  pattern upstream's own DaemonSet uses (upstream's own comment: "This
  DaemonSet does NOT request `nvidia.com/gpu`... accesses GPUs via device
  files in privileged mode"), not the NVIDIA device plugin.
