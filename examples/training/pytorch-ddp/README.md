# PyTorch DDP on JobSet

This Helm chart runs a small PyTorch `DistributedDataParallel` training job as one `JobSet` (`jobset.x-k8s.io/v1alpha2`), admitted by Kueue through a `LocalQueue`. Every few steps it writes a checkpoint to Amazon S3, and when the `JobSet` restarts after a failure it resumes from the newest checkpoint instead of step 0. It is the worked example for the platform's JobSet add-on ([#34](https://github.com/littlemex/distai-platform/issues/34)): the model is a toy two-layer network on random data, and the numbers it prints mean nothing; what is real is the NCCL collective, the gang restart and the resume.

The chart renders four objects into one namespace:

| Object | Purpose |
| --- | --- |
| `JobSet` | One replicated job, `worker`, with one `Job` and one Pod per node. Labelled `kueue.x-k8s.io/queue-name`, so Kueue keeps it suspended until the queue admits it |
| `ConfigMap` | The training script, `files/train.py`, mounted at `/opt/train` |
| `ServiceAccount` | The identity the Pods run as; the target of an EKS Pod Identity association for S3 access |
| `NetworkPolicy` | Ingress only from Pods of the same `JobSet` |

No custom container image is built. The Pods run the public `pytorch/pytorch` image, pinned by tag and digest, and install `boto3` at start.

## Layout

**Two nodes with one GPU each is the layout this chart's PR (issue #34) actually ran on real hardware** (see that PR's own Test Results): `--set workers.replicas=2 --set workers.gpusPerNode=1`. The chart starts torchrun with `--nnodes=2`, each Pod's node rank taken from the `jobset.sigs.k8s.io/job-index` annotation the JobSet controller sets, and the rank-0 Pod's stable host name (`<release>-worker-0-0.<release>`, from the `JobSet`'s headless `Service`) as the rendezvous address. NCCL reaches the other node over TCP sockets: the public PyTorch image has no libfabric and no `aws-ofi-nccl` plugin, so the `FI_*` variables the chart sets have no effect and `workers.efaPerNode` should stay `0` with this image. EFA between nodes needs an EFA-enabled image (`image.*`), `workers.efaPerNode` set to the number of EFA devices per node, and a `NodePool` whose `pool.networkInterfaces` attaches them. This layout also requests less of a GPU `NodePool`'s own `limits` per node than the default below (one GPU per node, not two) — the verification cell's own light-tier pool (`gitops/cells/dp-34-jobset-r1/capacity-pool/gpu.yaml`) has no `pool.limits.cpu` override wide enough for two of the default layout's two-GPU Pods to fit on one `g5`/`g6e`/`g7` node at once (every size in those families with 2+ GPUs needs 48+ vCPU; the chart's own default `NodePool` limit, inherited from `gitops/charts/capacity-pool`, is smaller) — see "Known issues".

The default is one node with two GPUs: `workers.replicas: 1` (one Pod) and `workers.gpusPerNode: 2` (torchrun starts one process per GPU, `--nproc-per-node=2`), fitting one `g5`, `g6e` or `g7` node with at least two NVIDIA GPUs, for example `g5.12xlarge` or `g6e.12xlarge` (both have 4). The two ranks would talk over the GPUs' own peer-to-peer and shared-memory paths, nothing over the network — **this is the chart's own shipped default, and is documented but not run as part of this PR's own verification** (the two-node layout above is what proves the issue's acceptance criteria instead; either shape satisfies them, since the issue accepts "two-node (or single-node, multi-GPU)").

## Prerequisites

| Requirement | Why |
| --- | --- |
| A cell built from `infra/foundation`, with `gitops/` bootstrapped | Kueue, and the `jobset-crd` core add-on (the `JobSet` CRD), are delivered to every cell |
| The `jobset` catalog entry opted into on the cell | The JobSet controller and webhook are `platform-optional`. Without them a `JobSet` is accepted by the API server but never runs. See "Opting a cell into JobSet" below |
| A team namespace onboarded with `gitops/bootstrap/team-onboard.sh` | Its `<team>-deployer` identity can create `JobSet`s, `ConfigMap`s, `ServiceAccount`s and `NetworkPolicy`s, and delete Pods. The namespace enforces Pod Security `restricted`; this chart's Pods meet it |
| A Kueue `LocalQueue` in that namespace, pointing at a `ClusterQueue` with quota on a GPU `ResourceFlavor` | `kueue.queueName`. `team-onboard.sh` does not create one; a cell administrator does. The cell's `distai-smoke` queue is CPU only and not usable here |
| A `NodePool` that can launch the GPU instance type the layout needs | For the default, one node with at least two NVIDIA GPUs and the device plugin method label (`gitops/README.md` "Accelerators"); for the two-node layout this PR verified, two nodes with at least one GPU each |
| An NVIDIA driver from the 580 series or later on the GPU nodes | The pinned image's CUDA 13.0 runtime needs it (see the `image.*` row in "Values" below) |
| An S3 bucket, and an EKS Pod Identity association for the chart's `ServiceAccount` to an IAM role that can read and write only the checkpoint prefix | The Pods read and write checkpoints. The association and role are created by a cell administrator; this chart does not create them. See the block below |
| Internet egress from the GPU nodes (the foundation's NAT gateway) | Pulling `pytorch/pytorch` from Docker Hub and `boto3` from PyPI at every Pod start |
| `kubectl`, Helm 3.8 or later, and the AWS CLI on your workstation | Rendering and applying the chart; the S3 and IAM steps |

The IAM role and Pod Identity association, run by a cell administrator. The role trusts the EKS Pod Identity service principal only, and allows `s3:ListBucket` on the bucket limited to the prefix, and `s3:GetObject`/`s3:PutObject` on objects under the prefix, nothing else:

```bash
set -euo pipefail

export AWS_REGION=us-east-1
export CLUSTER_NAME=my-cell
export NAMESPACE=team-a
export BUCKET=my-ddp-checkpoints-111122223333
export PREFIX=pytorch-ddp
export SERVICE_ACCOUNT=pytorch-ddp
export ROLE_NAME=pytorch-ddp-checkpoints

aws s3 mb "s3://${BUCKET}" --region "${AWS_REGION}"

cat > /tmp/pytorch-ddp-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "pods.eks.amazonaws.com"},
      "Action": ["sts:AssumeRole", "sts:TagSession"],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes-namespace": ["${NAMESPACE}"],
          "aws:RequestTag/kubernetes-service-account": ["${SERVICE_ACCOUNT}"],
          "aws:RequestTag/eks-cluster-name": ["${CLUSTER_NAME}"]
        }
      }
    }
  ]
}
EOF

cat > /tmp/pytorch-ddp-s3.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET}",
      "Condition": {"StringLike": {"s3:prefix": ["${PREFIX}/*"]}}
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/${PREFIX}/*"
    }
  ]
}
EOF

aws iam create-role --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/pytorch-ddp-trust.json
aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name pytorch-ddp-checkpoints \
  --policy-document file:///tmp/pytorch-ddp-s3.json

export ROLE_ARN=""
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)"
aws eks create-pod-identity-association --region "${AWS_REGION}" \
  --cluster-name "${CLUSTER_NAME}" --namespace "${NAMESPACE}" \
  --service-account "${SERVICE_ACCOUNT}" --role-arn "${ROLE_ARN}"
```

The association names the `ServiceAccount` by namespace and name, so it can be created before the chart is installed. If you change `checkpoint.prefix` or `serviceAccount.name`, change `PREFIX` or `SERVICE_ACCOUNT` above to match.

## Opting a cell into JobSet

A cell administrator adds one marker file, `gitops/cells/<cluster-name>/addons/jobset.yaml`, in a pull request. `dir`, `namespace` and `skipCrds` must equal the catalog entry's own (`gitops/addon-catalog/jobset/addon.yaml`; `gitops/tests/check_addon_catalog_sync.py` checks this). The only value a marker may override is `jobset.controller.resources`. The file's shape:

```yaml
addon: jobset
fromCatalog: jobset
dir: gitops/charts/jobset
namespace: jobset-system
skipCrds: true
wave: optional-1
```

Once the pull request merges and `stable` moves, `addons-optional.ApplicationSet.yaml` generates the `<cluster-name>-jobset` `Application`. The first time any cell opts in, re-run `gitops/bootstrap/bootstrap.sh` so the `platform` `AppProject`'s destinations include `jobset-system` (the script reads every catalog entry's namespace). Check that the controller is running:

```bash
kubectl rollout status deployment/jobset-controller -n jobset-system --timeout=5m
kubectl get crd jobsets.jobset.x-k8s.io
```

## Install

The chart is rendered with `helm template` and applied with `kubectl`, not installed with `helm install`: Helm stores a release as a `Secret` in the namespace, and a team's own identity is deliberately given no access to `Secret`s (`gitops/bootstrap/team-onboard.sh` step 3). Run this from a checkout of this repository, with an identity that holds at least the team's own `<team>-deployer` `Role` in the namespace (or a cell administrator's):

```bash
export AWS_REGION=us-east-1
export NAMESPACE=team-a
export RELEASE=ddp
export LOCAL_QUEUE=team-a-gpu
export BUCKET=my-ddp-checkpoints-111122223333
export PREFIX=pytorch-ddp

helm template "${RELEASE}" examples/training/pytorch-ddp \
  --namespace "${NAMESPACE}" \
  --set kueue.queueName="${LOCAL_QUEUE}" \
  --set checkpoint.bucket="${BUCKET}" \
  --set checkpoint.prefix="${PREFIX}" \
  --set checkpoint.region="${AWS_REGION}" \
  | kubectl apply -n "${NAMESPACE}" -f -
```

`checkpoint.prefix` is the whole key prefix for this run. A second run with the same prefix resumes from the first run's last checkpoint; use a new prefix for a fresh start, or delete the old objects.

## Watch it reach steady state

```bash
kubectl get jobset "${RELEASE}" -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" -l jobset.sigs.k8s.io/jobset-name="${RELEASE}" -w
```

The `JobSet` is created suspended and stays so until Kueue admits it; then one Pod per node is created, Karpenter launches a GPU node if none is free, and the image is pulled (about 3.3 GB). Once the Pod is `Running`, a checkpoint appears every `training.checkpointEvery` steps (20 steps, about 20 seconds, by default):

```bash
aws s3 ls "s3://${BUCKET}/${PREFIX}/"
kubectl wait jobset/"${RELEASE}" -n "${NAMESPACE}" --for=condition=Completed --timeout=60m
```

The training log carries stable markers, `[resume]`, `[checkpoint]` and `[done]`. Reading Pod logs needs `pods/log`, which a team's identity does not have (`team-rbac-guard.yaml` denies every subresource), so this step needs a cell administrator's identity:

```bash
kubectl logs -n "${NAMESPACE}" -l jobset.sigs.k8s.io/jobset-name="${RELEASE}" --tail=-1 | grep -E '^\[(init|resume|checkpoint|done)\]'
```

A first run prints `[resume] no checkpoint under s3://.../pytorch-ddp/, starting from step 0`, a `[checkpoint] wrote ...` line every 20 steps, and `[done] trained to step 200`.

## Test the restart and resume

Wait until at least one checkpoint exists, then delete the worker Pod while the run is still going (the default run lasts about 200 seconds after the Pod starts):

```bash
aws s3 ls "s3://${BUCKET}/${PREFIX}/"
kubectl delete pod -n "${NAMESPACE}" -l jobset.sigs.k8s.io/jobset-name="${RELEASE}"
kubectl get jobset "${RELEASE}" -n "${NAMESPACE}" -o jsonpath='{.status.restarts}{"\n"}'
```

The Pod's `Job` fails at once (`backoffLimit: 0`), so the `JobSet`'s own `failurePolicy` takes over: with `BlockingRecreate`, the controller deletes every `Job` of the `JobSet`, waits until all their Pods are gone, then recreates them, and `.status.restarts` goes from `0` to `1`. The new Pod's log (cell administrator identity, as above) starts with `[resume] loaded s3://.../step-<n>.pt, resuming from step <n>`, where `<n>` is the newest checkpoint before the deletion, and continues to `[done] trained to step 200`. After `failurePolicy.maxRestarts` (3) restarts, the next failure fails the `JobSet`.

`BlockingRecreate` rather than `Recreate` (which recreates `Job`s without waiting for the old Pods to go) is chosen so that a restarted run never has an old and a new rank alive at once, which with a static rendezvous address could let a new rank join a dying old one.

## Uninstall

```bash
helm template "${RELEASE}" examples/training/pytorch-ddp \
  --namespace "${NAMESPACE}" \
  --set kueue.queueName="${LOCAL_QUEUE}" \
  | kubectl delete -n "${NAMESPACE}" -f -
```

The checkpoints stay in S3 (`aws s3 rm "s3://${BUCKET}/${PREFIX}/" --recursive` removes them). The IAM role and the Pod Identity association are the cell administrator's to remove.

## Values

| Value | Default | Meaning |
| --- | --- | --- |
| `kueue.queueName` | `team-queue` | `LocalQueue` in the install namespace. Set it to your own cell's queue; rendering fails if it is empty |
| `checkpoint.bucket` / `.prefix` / `.region` | `""` / `pytorch-ddp` / `""` | Where checkpoints go: `s3://<bucket>/<prefix>/step-<n>.pt`. The container exits with a message until bucket and region are set |
| `workers.replicas` | `1` | Nodes; one Pod and one `Job` each |
| `workers.gpusPerNode` | `2` | GPUs per Pod, and torchrun processes per Pod |
| `workers.efaPerNode` | `0` | `vpc.amazonaws.com/efa` devices per Pod; only with an EFA-enabled image |
| `workers.gpuResourceName` | `nvidia.com/gpu` | Extended resource the GPU device plugin advertises |
| `workers.resources` | 4 CPU, 16Gi requested | CPU and memory; the GPU (and EFA) limit is added from the values above |
| `workers.nodeSelector` / `.tolerations` | `{}` / `[]` | Kueue injects the admitting `ResourceFlavor`'s; set only without Kueue |
| `workers.env` | `FI_PROVIDER`, `FI_EFA_FORK_SAFE`, `NCCL_DEBUG`, `NCCL_SOCKET_IFNAME`, `GLOO_SOCKET_IFNAME`, `TORCH_NCCL_ASYNC_ERROR_HANDLING` | From `awslabs/awsome-distributed-ai`'s FSDP Kubernetes recipe; see `values.yaml` for which of that recipe's variables are left out and why |
| `workers.extraEnv` | `[]` | More environment variables |
| `workers.shmSizeLimit` | `8Gi` | Size of the memory-backed `/dev/shm` |
| `workers.masterPort` | `29500` | Rendezvous port, two-node layout only |
| `workers.podSecurityContext`, `.containerSecurityContext` | UID 1000, all capabilities dropped | Meets Pod Security `restricted` |
| `failurePolicy.restartStrategy` / `.maxRestarts` | `BlockingRecreate` / `3` | The `JobSet`'s gang restart policy |
| `training.totalSteps` / `.checkpointEvery` / `.stepSleepSeconds` | `200` / `20` / `1` | Length of the run, checkpoint interval, pause per step |
| `image.repository` / `.tag` / `.digest` | `pytorch/pytorch` / `2.14.1-cuda13.0-cudnn9-runtime` / pinned | CUDA 13.0 runtime; needs an NVIDIA driver from the 580 series or later |
| `boto3Version` | `1.44.12` | `boto3` version installed at Pod start |
| `serviceAccount.create` / `.name` | `true` / `pytorch-ddp` | The Pods' identity, and the Pod Identity association's target |
| `networkPolicy.enabled` | `true` | Ingress only from Pods of the same `JobSet` |

## Known issues

- `boto3` is installed with `pip install --no-cache-dir --target` at every Pod start, because no custom image is built for this example. Every start, including every restart, needs egress to PyPI and adds a few seconds; a PyPI outage makes the Pod exit and counts as a `JobSet` failure. A real training image should carry its dependencies.
- The default image is about 3.3 GB compressed and is pulled on every new node.
- Only rank 0 writes checkpoints, and only the model and optimizer state, not the data generator's own position. This does not break reproducibility, though: each step's random batch is seeded from `(step, world_size, rank)` (`files/train.py`), not from an accumulating generator state, so a resumed run regenerates the identical "random" data for every step at and after the one it resumed from. A checkpoint is one `PutObject`, so a Pod killed during a write leaves the previous checkpoint as the newest.
- Every rank lists S3 and loads the checkpoint independently on resume, rather than rank 0 broadcasting `start_step` to the others — a known simplification (see `files/train.py`'s own comment on the `dist.barrier()` call, which only synchronizes timing across ranks, not each rank's own computed value).
- Old checkpoints are never deleted by the script.
- Pod logs and Kueue `Workload` objects are not readable with a team's own identity (no `pods/log` and no `kueue.x-k8s.io` access in its `Role`); watching the run in detail needs a cell administrator.
- `automountServiceAccountToken: false` is set on the `ServiceAccount`, since the Pods never call the Kubernetes API. EKS Pod Identity injects its own token volume and does not depend on the automounted token; confirmed on this chart's own real-hardware run (this PR's own Test Results) — the Pods read S3 successfully with this setting.
- The default, single-node two-GPU layout is documented but not run as part of this PR's own verification (see "Layout" above for why, and which layout was run instead).
