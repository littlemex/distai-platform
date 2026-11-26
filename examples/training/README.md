# Training Examples

Self-contained references for running real distributed training jobs on an EKS cluster through this platform's JobSet add-on ([#34](https://github.com/littlemex/distai-platform/issues/34), `gitops/addons/jobset-crd/`, `gitops/addon-catalog/jobset/`). Each example is deployed with `helm`/`kubectl` directly and does not depend on this repository's GitOps delivery; the cluster only has to already have the `jobset-crd` core add-on (every cell has it) and the `jobset` catalog entry opted in (`gitops/cells/<cell>/addons/jobset.yaml`), plus whatever GPU/EFA device plugin and `NodePool` the example's own README lists. Examples are grouped by what they exercise, and each one has its own README with prerequisites, copy-paste instructions and known issues.

| Example | Description |
| --- | --- |
| [`pytorch-ddp`](pytorch-ddp/) | A small PyTorch `DistributedDataParallel` job as one `JobSet`, admitted by Kueue as a gang, writing and resuming from an Amazon S3 checkpoint. The worked example for #34's own acceptance criteria |

## Status

| Example | Built | Run on real hardware |
| --- | --- | --- |
| [`pytorch-ddp`](pytorch-ddp/) | Yes: chart, README and static checks (`helm lint`/`helm template`/`check_training_render.py` on the runner) | Yes, the two-node layout (`workers.replicas=2`, `workers.gpusPerNode=1`) -- all four of #34's own acceptance criteria passed on a real `us-east-1` cell, see that issue's own pull request Test Results. The chart's own single-node default layout is not yet run on real hardware (see the chart's own README "Layout") |

## Conventions

- No example here builds a custom container image; each one pins an existing public image by tag and digest.
- A `JobSet`'s Pod template carries `kueue.x-k8s.io/queue-name`; nothing here creates its own `LocalQueue` or `ClusterQueue` -- a cell administrator provides one, the same convention `examples/inference/` follows for its own GPU/EFA prerequisites.
- Checkpoint storage is Amazon S3, read and written directly by the training container (an EKS Pod Identity association an administrator creates, scoped to one bucket/prefix) -- not a `PersistentVolumeClaim` or FSx for Lustre; see each example's own README for why.

<!-- ci-verify: throwaway smoke test for .github/workflows/static-checks.yml, see PR -->
