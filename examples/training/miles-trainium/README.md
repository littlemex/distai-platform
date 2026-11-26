# GRPO-style post-training smoke test: SGLang-Neuron rollout on Trainium

This is a reference for one narrow question: can a GRPO-style post-training loop (generate, reward, train, update the policy's weights) close at least once when the rollout step runs through [`sgl-project/sglang-neuron`](https://github.com/sgl-project/sglang-neuron) -- the public preview SGLang platform plugin for AWS Trainium -- on one real `trn2.3xlarge` node? It is not `miles` (`radixark/miles`) itself, and it is not `miles`'s own training backend (Megatron-LM, `fsdp` or `torchtitan`); see "Relationship to miles" below for why. **Result: not yet closed.** A real `trn2.3xlarge` spot node, its device plugin, and the 11.7 GB `sglang-neuron` image all worked; the container itself exited about 72 seconds after starting (exit code 2, most consistent with the sglang-neuron server itself failing rather than a setup-script error -- see "On the exit code" below). No application-level log line was captured. See "What actually ran" for the evidence and "Still not working" for the unverified fixes applied as a result.

## Relationship to miles

`awslabs/awsome-distributed-ai`'s `examples/training/miles` already references `miles`, a fork of `slime`, for GRPO post-training on GPU (Megatron-LM + SGLang + Ray). `miles`'s own weight-transfer protocols are pluggable (`cuda_ipc`, `broadcast`/NCCL, `disk-delta`, `p2p`, `http_lora`, `ici` for TPU), but its rollout backend is SGLang only, with no abstraction for swapping the inference engine itself. `sglang-neuron`'s own documentation states its weight-update and LoRA endpoints are refused (see "What SGLang-Neuron does not support" below), so `miles`'s existing rollout client cannot be pointed at it unmodified. This example does not attempt that swap; it is a standalone, minimal reference built specifically to answer the rollout-on-Trainium question on its own, written against `sglang-neuron`'s actual, documented API rather than through `miles`.

## What SGLang-Neuron is, and is not, documented to support

- `sgl-project/sglang-neuron` is an independent plugin (not part of core `sgl-project/sglang`), pinned to upstream SGLang commit `43881a7`, published by the AWS Neuron team through Amazon ECR Public. Current release: `v0.1.0`, image `public.ecr.aws/neuron/pytorch-inference-sglang-neuron:v0.1.0-neuron-py314-sdk-2.33.0-ubuntu26.04` (11.7 GB across 41 layers, by its own registry manifest).
- Its own docs state: *"This release is a public preview."*
- Its own model-recipe docs ([`docs/model-recipes/qwen3.md`](https://github.com/sgl-project/sglang-neuron/blob/4e2432622bfab2c6663d12286a6813ef1a40bfe6/docs/model-recipes/qwen3.md)) state LLM serving (Qwen3, GLM-4, DeepSeek-V2-Lite, GPT-OSS and others) "runs on Trn3 instances"; diffusion models (FLUX, Wan2.2 and others) target `trn2.48xlarge`. **Neither doc names `trn2.3xlarge`.** This example runs LLM serving on `trn2.3xlarge` anyway, off-label by the project's own documentation, because the validated flags for Qwen3-0.6B ask for exactly four NeuronCores (`--tp-size 4`) -- the same count `trn2.3xlarge`'s device plugin advertises (confirmed on real hardware by this investigation: `aws.amazon.com/neuron: "1"`, `aws.amazon.com/neuroncore: "4"` allocatable) -- not because the instance is a documented target.
- "What is refused" (close paraphrase of the same doc's own section): a non-bfloat16 dtype; a quantized checkpoint; sliding-window attention; attention biases; a scaled RoPE; attention/KV head counts that do not split or replicate evenly over the tensor-parallel ranks; `--ep-size` other than 1; a KV cache dtype other than `auto`/`bf16`; and, from the plugin's own LoRA/weight-update documentation, dynamic weight reload and LoRA adapters. **There is no live-reload API** (no equivalent of upstream SGLang's `/update_weights_from_disk`); the only officially-supported way to pick up new weights is to restart the server pointed at a new checkpoint directory.

## Design

| Part | Where it runs | Why |
|---|---|---|
| Rollout (generation) | `sgl-project/sglang-neuron`, `--tp-size 4`, all four NeuronCores of one `trn2.3xlarge` | The actual rollout engine this reference is testing, through its own OpenAI-compatible `/v1/completions` route |
| Reward | Plain Python (CPU, in the same Pod) | A free, deterministic rule (count of alphabetic words); the number itself is not the point, only that it varies across samples so GRPO's group-relative advantage has something to normalize |
| Training (loss, backward, optimizer step) | Plain CPU `transformers` (eager, variable-length batches), same Pod | `sglang-neuron`'s own `--tp-size 4` already claims every NeuronCore this node's device plugin advertises, so a second NeuronCore-bound process has nowhere to run. A 0.6B model's forward+backward over a handful of short sequences is cheap enough on CPU that this is a legitimate choice for a correctness smoke test, not a shortcut around a real blocker -- see "Still not working" if this assumption turns out to be wrong at a larger model size |
| Weight update | Restart `sglang-neuron` pointed at a freshly-saved checkpoint | The only officially-supported reload path (see above); no unofficial patch |

## What actually ran (this investigation's own evidence)

Three real-machine attempts, on a disposable cell built and torn down for each (`infra/foundation` + `gitops/` bootstrap, 83 resources each, independently re-verified clean with a read-only AWS sweep after every attempt -- zero leftover instance/ENI/NAT/volume/launch-template/VPC):

| Attempt | Result |
|---|---|
| 1 | An orchestration mistake in this investigation's own verification script, not a platform or SGLang-Neuron issue: the gitops cell directory for the cell name used did not exist, so no capacity-pool/namespace was ever delivered and the run failed before requesting any Trainium capacity. |
| 2 | Pod stayed `Pending` with no node assigned for the full 15-minute wait. A read-only check immediately afterward found zero `trn2.3xlarge` instances running anywhere in the account at that moment; no Karpenter NodeClaim event was captured for this attempt specifically to confirm why. Consistent with a transient spot-capacity shortage in the one Availability Zone of `ap-southeast-4` that offers this instance type, but not confirmed as the sole cause. |
| 3 | **A real node launched and the image pulled authenticated** (a `trn2.3xlarge` spot instance; node allocatable `aws.amazon.com/neuron: "1"`, `aws.amazon.com/neuroncore: "4"`; image `public.ecr.aws/neuron/pytorch-inference-sglang-neuron:v0.1.0-...` pulled in 3m3.6s, 11.7 GB). A `TaintManagerEviction` event marked the pod for deletion once, and a later event recorded `Cancelling deletion of Pod` for the same pod; whether the `karpenter.sh/do-not-disrupt` annotation caused that specifically, versus the ordinary node-readiness taint-eviction path, is not confirmed by a controller log line. The container started, ran for about 72 seconds, and exited with code 2; the Job's own status recorded `BackoffLimitExceeded` / `Failed`. **No application-level log line was ever captured**: this investigation's own `kubectl logs -f` hit its own client-side `context deadline exceeded` while the pod was still `ContainerCreating`, before the container ever started, and nothing re-attached it afterward (fixed in `0.verify.sh`, but not re-verified). |

**On the exit code.** `train_grpo.py` has exactly one `sys.exit(2)` call, inside `wait_health()`, reached only when the `sglang-neuron` server subprocess itself has already exited or never answers `/health`. A missing CLI tool under `bash -lc`/`set -e` would exit 127, and a Python import or argument error would typically exit 1 -- neither matches. The exit code is therefore more consistent with `train_grpo.py` having started, run its setup `pip install`, and launched the `sglang-neuron` server, which then failed on its own within the ~72-second lifetime, than with a failure in the setup commands as an earlier draft of this document guessed. The server's own reason is not known: its log goes to a file inside the container (`/tmp/sglang-neuron-server.log`) that disappeared with it, and no script here captured it before teardown. **The loop did not close.** What is directly confirmed on real hardware: the platform's own `capacity-pool` + `accel-neuron-device-plugin` mechanism delivering a `trn2.3xlarge` with the right device count, and an authenticated pull of `sglang-neuron`'s 11.7 GB image. What is not confirmed: that the `sglang-neuron` server itself ever became healthy, or why it did not.

## Prerequisites

| Requirement | Why |
| --- | --- |
| A cell built from `infra/foundation`, with `gitops/` bootstrapped | Kueue and the core add-ons, delivered to every cell |
| A `trn2.3xlarge` light-tier Trainium `NodePool` (`gitops/charts/capacity-pool`, `accelerator.methodLabel` = `distai.dev/neuron-method: device-plugin`) | This example's `nodeSelector`/toleration target it directly |
| A namespace this Job can run in (here, `distai-smoke`) -- the Job does not use Kueue admission | Where the Job and its ConfigMap/Secret are created |
| Internet egress from the Trainium node (the foundation's NAT gateway) | Pulling the 11.7 GB `sglang-neuron` image and downloading `Qwen/Qwen3-0.6B` from Hugging Face |
| `kubectl` and the AWS CLI on your workstation | Running the procedure below |

## Procedure (copy, paste, run)

```bash
export CLUSTER_NAME=your-cell-name
export AWS_REGION=your-region
export NAMESPACE=distai-smoke
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
ECR_PUBLIC_PASSWORD="$(aws ecr-public get-login-password --region us-east-1)"
kubectl create secret docker-registry ecr-public-pull -n "${NAMESPACE}" \
  --docker-server=public.ecr.aws --docker-username=AWS --docker-password="${ECR_PUBLIC_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset ECR_PUBLIC_PASSWORD
kubectl create configmap miles-trainium-script -n "${NAMESPACE}" \
  --from-file=train_grpo.py=./train_grpo.py --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f job.yaml
kubectl wait --for=condition=complete --timeout=60m job/miles-trainium-grpo -n "${NAMESPACE}" || true
kubectl logs job/miles-trainium-grpo -n "${NAMESPACE}"
```

This Job does not go through Kueue admission (it carries no `kueue.x-k8s.io/queue-name` label), so "namespace this Job can run in" above means only that -- a namespace, not a configured `LocalQueue`. `0.verify.sh` (below) is this investigation's own end-to-end verification: it also builds and tears down a disposable cell from scratch (which this simpler procedure assumes already exists), and itself needs a `gitops/cells/${NAME}/` directory with a trn2.3xlarge pool to exist on whatever revision it bootstraps -- this PR does not add a new one, so point it at an existing fixture or add your own first (`gitops/README.md` "Adding a cell").

## Still not working / known limits

- **The loop has not closed on real hardware yet.** Attempt 3 (above) is the closest real-machine result: node, device plugin and authenticated image pull all confirmed working, but the container exited (code 2, most consistent with the `sglang-neuron` server itself failing -- see "On the exit code" above) about 72 seconds in, before any application log line was captured. This investigation's own granted real-machine attempts ran out at that point. Three fixes are applied here as a result, none re-verified: (1) `job.yaml`'s model download now uses `huggingface_hub.snapshot_download` from Python instead of the `hf` CLI, which this image was not confirmed to carry; (2) `0.verify.sh`'s log-streaming now relaunches `kubectl logs -f` whenever it exits early, so a client-side timeout while a container is still `ContainerCreating` no longer loses every later log line; (3) `train_grpo.py` now prints the `sglang-neuron` server's own log file to its own stdout whenever the server fails to start or become healthy, so a future `kubectl logs` capture carries the server's actual reason instead of only this script's `sys.exit(2)`.
- **Everything about how `sglang-neuron` is actually launched here is unverified on this instance size.** `train_grpo.py` invokes the image's own `/opt/sglang-neuron/examples/qwen3_0p6b/run_server.sh` with `MODEL_PATH` overridden, and talks to it on port 30000 via `/health` and the OpenAI-compatible `/v1/completions` route (with an `n` sampling parameter) -- all read from the plugin's own docs, none confirmed by a real run that got far enough to reach them.
- `trn2.3xlarge` for LLM serving is off-label per `sglang-neuron`'s own docs (see above) -- a future SDK/plugin release could narrow or change what actually runs on this instance size without notice.
- The weight-update path is a full server restart, not a live reload -- the officially-supported method, not a workaround this example invented -- but its latency was never measured here, since the loop did not reach a second step. A separate, third-party public repository (`pengchenglu1997/trainium-sglang-rl`, read 2026-11-26) measured a comparable restart-based reload around 455-460 seconds for a similarly small model on larger Trainium hardware; treat that as unrelated context, not this example's own result.
- Training runs on CPU, not on a NeuronCore -- correct for proving the loop closes at this model size, not representative of a production training step's cost or throughput.
- `Qwen/Qwen3-0.6B` is downloaded by name, not pinned to a specific Hugging Face Hub revision -- a future upstream change to that model could change behavior without this example noticing.
