# Tests for examples/training

Checks for [issue #34](https://github.com/littlemex/distai-platform/issues/34)'s worked example, `examples/training/pytorch-ddp` (a JobSet-based PyTorch DDP recipe admitted through Kueue, with EFA/NCCL environment, a group-restart `failurePolicy` and checkpoint/resume to Amazon S3 through a ServiceAccount meant for an EKS Pod Identity association), and for the delivery of JobSet itself.

| Script | What it checks | Needs AWS | Duration |
| --- | --- | --- | --- |
| `0.static.sh` | Required files, `bash -n`/`shellcheck`, `py_compile`/`ruff`, `check_training_render.py --selftest`, `helm lint`/`helm template` with the test values (default replica count and the two-node variant), the rendered objects (`check_training_render.py`, rules R1-R11 in its header), `kubeconform -strict` of the built-in kinds, and the resume log line the e2e greps for | No | About 1 minute |
| `1.e2e.sh` | On a real cell that opted into the `jobset` catalog entry: delivery, team self-service, gang admission, checkpoint and resume (steps below) | Yes | About 30 to 60 minutes, most of it GPU node launch |

The add-on pair and the RBAC widening are checked statically in `gitops/tests/` (`check_jobset_addon.py`, `check_team_rbac_guard.py`, both run by `gitops/tests/0.static.sh`).

## Traceability

| Issue #34 acceptance criterion | Static check | Real-cluster check (`1.e2e.sh`) |
| --- | --- | --- |
| The JobSet add-on is delivered (Proposed Change: `jobset-crd` core in `crds`, `jobset` platform-optional with `skipCrds`/`dependsOn`, Kueue unchanged) | `gitops/tests/check_jobset_addon.py` 1-7, N1-N3 | Step 1: `<cell>-jobset-crd` and `<cell>-jobset` Synced/Healthy, CRD Established, controller Available, Kueue's live config lists `jobset.x-k8s.io/jobset` |
| A team submits a JobSet under its own identity (Proposed Change: the `team-rbac-guard.yaml` and `team-onboard.sh` step 3 widening) | `gitops/tests/check_team_rbac_guard.py` (allow `jobsets` CRUD; deny `jobsets/status`, `*`, `deletecollection`, Kueue kinds; the onboarding Role itself allowed); R8 (Pod Security `restricted`), R10 (every rendered kind creatable by the deployer Role) | Step 2: `team-onboard.sh` for a disposable team, the live guard both ways, `<team>-deployer` (`kubectl --as`) applies the rendered chart itself |
| Criterion 1: a training Job reaches a running steady state and writes at least one checkpoint to S3 | R5 (torchrun, accelerator, `FI_PROVIDER=efa`, `NCCL_*`), R6 (Pod Identity ServiceAccount), R7 (bucket/prefix reach the container) | Steps 3-4: every worker Running, a checkpoint object under the run's own prefix |
| Criterion 2: killing one worker triggers the JobSet restart and the job resumes from the last checkpoint | R3 (`BlockingRecreate`, `maxRestarts >= 1`), R4 (`backoffLimit: 0`, so the JobSet, not the Job controller, reacts), resume log line present | Step 4: one Pod deleted, `status.restarts` moves, every first-attempt Pod replaced, restarted workers log a resume step at least as new as the last checkpoint before the kill, and a newer checkpoint follows |
| Criterion 3: gang admission, zero workers when under-provisioned | R2 (`kueue.x-k8s.io/queue-name` label), R4 (one replicatedJob, replica count) | Step 3: ClusterQueue one Pod short, zero Pods for the whole window, Workload without quota, JobSet suspended; then sized, admitted for every Pod at once, all Running |
| Criterion 4: runs on a light-tier GPU pool (`g5`/`g6e`/`g7` spot) | - | Step 3: each worker's node family is in `LIGHT_TIER_FAMILIES` and its capacity type is `EXPECT_CAPACITY_TYPE` |

## What the tests assume about the chart

`chart-contract.sh` is the one place that names what the tests assume and the issue does not fix: the `values.yaml` key names they set (queue name, replica count, GPUs per Pod, ServiceAccount name, checkpoint bucket/prefix/interval, total steps), how a checkpoint object key carries its step number, and the log line the training script prints when it resumes. Each is marked `NOTE`. If the chart differs, change that file; the checks themselves look for the values they set in the rendered objects and do not depend on the key names.

## Running

```bash
./examples/training/tests/0.static.sh
```

```bash
export AWS_PROFILE=test AWS_REGION=us-east-1 NAME=test-cell
export CHECKPOINT_BUCKET=example-checkpoints CHECKPOINT_PREFIX=t34
export CHECKPOINT_ROLE_ARN=arn:aws:iam::111122223333:role/example-checkpoint-writer
export GPU_RESOURCE_FLAVOR=gpu
./examples/training/tests/1.e2e.sh
```

Prerequisites for `1.e2e.sh`: Bash 4 or later, `aws`, `jq`, `kubectl`, `helm`, and a `python3` with PyYAML. The cell must already carry `gitops/cells/<cell>/addons/jobset.yaml` at the revision it tracks (this script never pushes to Git). `E2E_REPLICAS` must be at least 2 (default 2): with one Pod, "all or none" cannot be told apart from "partial". With the default `GPUS_PER_POD=2`, the pool must be able to launch four GPUs in total.
