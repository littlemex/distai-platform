# GRPO-style post-training smoke test: SGLang-Neuron rollout on Trainium

This is a reference for one narrow question: can a GRPO-style post-training loop (generate,
reward, train, update the policy's weights) close at least once when the rollout step runs
through [`sgl-project/sglang-neuron`](https://github.com/sgl-project/sglang-neuron) -- the public
preview SGLang platform plugin for AWS Trainium -- on one real `trn2.3xlarge` node? It is not
`miles` (`radixark/miles`) itself, and it is not `miles`'s own training backend (Megatron-LM,
`fsdp` or `torchtitan`); see "Relationship to miles" below for why. [FILL IN: one-line result --
closed N step(s) / got to step X and stopped at Y].

## Relationship to miles

`awslabs/awsome-distributed-ai`'s `examples/training/miles` already references `miles`, a fork of
`slime`, for GRPO post-training on GPU (Megatron-LM + SGLang + Ray). `miles`'s own weight-transfer
protocols are pluggable (`cuda_ipc`, `broadcast`/NCCL, `disk-delta`, `p2p`, `http_lora`, `ici` for
TPU), but its rollout backend is SGLang only, with no abstraction for swapping the inference
engine itself. `sglang-neuron`'s own documentation states its weight-update and LoRA endpoints
are refused (see "What SGLang-Neuron does not support" below), so `miles`'s existing rollout
client cannot be pointed at it unmodified. This example does not attempt that swap; it is a
standalone, minimal reference built specifically to answer the rollout-on-Trainium question on
its own, written against `sglang-neuron`'s actual, documented API rather than through `miles`.

## What SGLang-Neuron is, and is not, documented to support

- `sgl-project/sglang-neuron` is an independent plugin (not part of core `sgl-project/sglang`),
  pinned to upstream SGLang commit `43881a7`, published by the AWS Neuron team through Amazon ECR
  Public. Current release: `v0.1.0`, image
  `public.ecr.aws/neuron/pytorch-inference-sglang-neuron:v0.1.0-neuron-py314-sdk-2.33.0-ubuntu26.04`
  (11.7 GB across 41 layers, by its own registry manifest).
- Its own docs state: *"This release is a public preview."*
- Its own model-recipe docs ([`docs/model-recipes/qwen3.md`](https://github.com/sgl-project/sglang-neuron/blob/main/docs/model-recipes/qwen3.md))
  state LLM serving (Qwen3, GLM-4, DeepSeek-V2-Lite, GPT-OSS and others) "runs on Trn3 instances";
  diffusion models (FLUX, Wan2.2 and others) target `trn2.48xlarge`. **Neither doc names
  `trn2.3xlarge`.** This example runs LLM serving on `trn2.3xlarge` anyway, off-label by the
  project's own documentation, because the validated flags for Qwen3-0.6B ask for exactly four
  NeuronCores (`--tp-size 4`) -- the same count `trn2.3xlarge`'s device plugin advertises
  (confirmed on real hardware by this investigation: `aws.amazon.com/neuron: "1"`,
  `aws.amazon.com/neuroncore: "4"` allocatable) -- not because the instance is a documented
  target.
- "What is refused" (same doc, verbatim): a model dtype other than bfloat16; a quantized
  checkpoint; sliding-window attention; attention biases; a scaled RoPE; attention/KV head counts
  that do not split or replicate evenly over the tensor-parallel ranks; `--ep-size` other than 1;
  a KV cache dtype other than `auto`/`bf16`; and, from the plugin's own LoRA/weight-update
  documentation, dynamic weight reload and LoRA adapters. **There is no live-reload API** (no
  equivalent of upstream SGLang's `/update_weights_from_disk`); the only officially-supported way
  to pick up new weights is to restart the server pointed at a new checkpoint directory.

## Design

| Part | Where it runs | Why |
|---|---|---|
| Rollout (generation) | `sgl-project/sglang-neuron`, `--tp-size 4`, all four NeuronCores of one `trn2.3xlarge` | The actual rollout engine this reference is testing, through its own OpenAI-compatible `/v1/completions` route |
| Reward | Plain Python (CPU, in the same Pod) | A free, deterministic rule (count of alphabetic words); the number itself is not the point, only that it varies across samples so GRPO's group-relative advantage has something to normalize |
| Training (loss, backward, optimizer step) | Plain CPU `transformers` (eager, variable-length batches), same Pod | `sglang-neuron`'s own `--tp-size 4` already claims every NeuronCore this node's device plugin advertises, so a second Neuron-side process has nowhere to run. A 0.6B model's forward+backward over a handful of short sequences is cheap enough on CPU that this is a legitimate choice for a correctness smoke test, not a shortcut around a real blocker -- see "Still not working" if this assumption turns out to be wrong at a larger model size |
| Weight update | Restart `sglang-neuron` pointed at a freshly-saved checkpoint | The only officially-supported reload path (see above); no unofficial patch |

## What actually ran (this investigation's own evidence)

[FILL IN after verify_on_runner.sh's own run: instance ID / type, node allocatable, step count,
reward and loss per step, wall-clock time per phase, and where it stopped if it did not finish.]

## Prerequisites

| Requirement | Why |
| --- | --- |
| A cell built from `infra/foundation`, with `gitops/` bootstrapped | Kueue and the core add-ons, delivered to every cell |
| A `trn2.3xlarge` light-tier Trainium `NodePool` (`gitops/charts/capacity-pool`, `accelerator.methodLabel` = `distai.dev/neuron-method: device-plugin`) | This example's `nodeSelector`/toleration target it directly |
| A Kueue `LocalQueue`/namespace this Job can run in (here, `distai-smoke`) | Where the Job and its ConfigMap/Secret are created |
| Internet egress from the Trainium node (the foundation's NAT gateway) | Pulling the 11.7 GB `sglang-neuron` image and downloading `Qwen/Qwen3-0.6B` from Hugging Face |
| `kubectl` and the AWS CLI on your workstation | Running the procedure below |

## Procedure (copy, paste, run)

```bash
export CLUSTER_NAME=your-cell-name
export AWS_REGION=your-region
export NAMESPACE=distai-smoke
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
aws ecr-public get-login-password --region us-east-1 | \
  kubectl create secret docker-registry ecr-public-pull -n "${NAMESPACE}" \
    --docker-server=public.ecr.aws --docker-username=AWS --docker-password-stdin \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap miles-trainium-script -n "${NAMESPACE}" \
  --from-file=train_grpo.py=./train_grpo.py --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f job.yaml
kubectl wait --for=condition=complete --timeout=60m job/miles-trainium-grpo -n "${NAMESPACE}" || true
kubectl logs job/miles-trainium-grpo -n "${NAMESPACE}"
```

## Still not working / known limits

[FILL IN based on the real run: e.g. restart-based weight reload latency measured; any
compile/startup time; any step that did not complete and why.]

- `trn2.3xlarge` for LLM serving is off-label per `sglang-neuron`'s own docs (see above) -- a
  future SDK/plugin release could narrow or change what actually runs on this instance size
  without notice.
- The weight-update path is a full server restart, not a live reload; this is slow (see the
  measurement above) and is the officially-supported method, not a workaround this example
  invented.
- Training runs on CPU, not on a NeuronCore -- correct for proving the loop closes at this model
  size, not representative of a production training step's cost or throughput.
