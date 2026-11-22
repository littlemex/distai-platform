# SGLang aggregated baseline

This Helm chart serves one model the ordinary way: each SGLang engine runs prefill and decode in the same process, with no disaggregation. It is the comparison point for the [SGLang prefill/decode disaggregated chart](../disagg-pd/): same pinned image, same model values, same metrics, so that a comparison run on the same hardware changes the layout and nothing else. It has the same shape and value names as the [vLLM aggregated baseline](../../vllm/agg-baseline/).

## Status

**Run on real hardware** (`g7.8xlarge`, light tier, RFC [#37](https://github.com/littlemex/distai-platform/issues/37) follow-up issue C): the engine reached `Running`/`Ready` and served a real OpenAI-compatible completion (a real generated answer, not an error). A 40-request open-loop load-replay against `_shared/load-replay`/`score.py`, at a fixed, low, non-saturating rate (2 req/s), completed with `successful_requests=40`/`failed_requests=0`, `joint_attainment_share=1.0` and `goodput_per_gpu≈2.02` (that rate over 1 GPU, comfortably under every SLO limit — a smoke result, not a saturation or efficiency measurement). This round's Prometheus check (a minimal, in-cluster instance, confirmed scraping a real, nonzero `vllm:*` metric value) was run against the `vllm/agg-baseline` chart only; this SGLang chart's own `/metrics` was not inspected and is not independently confirmed scraped. [`../../tests/0.static.sh`](../../tests/0.static.sh) now covers this chart's own `helm lint`/`helm template`/kubeconform (it did not before this round).

## The tuned baseline

SGLang's shipped scheduler defaults are not the tuned aggregated configuration, unlike vLLM's. Mixed chunked prefill (running decodes batched together with a prefill chunk, so a long prompt does not stall every answer in progress) is off by default (`enable_mixed_chunk = False` in `python/sglang/srt/arg_groups/fields/schedule.py`), and when `--chunked-prefill-size` is not given, SGLang picks a chunk size between 2048 and 16384 tokens from the GPU's memory (`python/sglang/srt/arg_groups/memory_hook.py`). The chart therefore always passes both: `--enable-mixed-chunk` and `--chunked-prefill-size 8192` by default (`engine.scheduler`). The fixed chunk size makes the baseline the same on every GPU type; record it with every result. A claim that disaggregation is better is only evidence against this baseline measured in the same run series, with the same trace and the same SLO (RFC #37, Decisions 8 and 10).

## Prerequisites

| Requirement | Why |
| --- | --- |
| An EKS cluster with NVIDIA GPU nodes and the NVIDIA device plugin (`nvidia.com/gpu`) | Engines request GPUs as an extended resource |
| Nodes that can pull `lmsysorg/sglang` from Docker Hub and model weights from Hugging Face | The image and the weights are downloaded at start |
| `kubectl` and Helm 3.8 or later on your workstation | Installing the chart |

No EFA device is needed: nothing leaves the engine.

## Image

`lmsysorg/sglang:v0.5.23-efa`, pinned by digest `sha256:644f315d1d48ade2f95d76c2a8a802541a027e7e56af289b17bd5d1fdf4c8fe7` (the multi-arch index). v0.5.23 is the latest stable SGLang release as of 2026-11-22 ([GitHub releases](https://github.com/sgl-project/sglang/releases/tag/v0.5.23)); the digest is the `Docker-Content-Digest` that Docker Hub's registry returns for that tag (`registry-1.docker.io/v2/lmsysorg/sglang/manifests/v0.5.23-efa`, checked 2026-11-22), and matches the digest on the tag's [Docker Hub page](https://hub.docker.com/r/lmsysorg/sglang/tags?name=v0.5.23-efa). The image records the SGLang commit it was built from (`SGLANG_BUILD_COMMIT=297e54fd105e974cdf401e5b4d20253a22c16f90`, the `v0.5.23` tag), and source paths cited in this README are at that commit. The `-efa` variant is used here only so that both SGLang charts run the same image; this chart itself needs nothing it adds.

## Deploy

```bash
git clone https://github.com/littlemex/distai-platform.git
cd distai-platform
export NAMESPACE=pd-demo
export RELEASE=agg
export MODEL_ID="${MODEL_ID:?set MODEL_ID to a Hugging Face model repository id}"
helm install "$RELEASE" examples/inference/sglang/agg-baseline \
  --namespace "$NAMESPACE" --create-namespace \
  --set model.name="$MODEL_ID"
kubectl rollout status deployment -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" --timeout=40m
```

To compare with a disaggregated run, give this release the same total number of GPUs (`engine.replicas` x `engine.gpusPerEngine` equal to the prefill plus decode GPUs of the other release) and the same kind of nodes, for example by selecting a node labeled for one of the disaggregated roles with `--set-string 'engine.nodeSelector.distai\.dev/pd-role=prefill'`. Pin `model.revision` on both releases.

## Verify

```bash
kubectl run curl-agg --rm -i --restart=Never -n "$NAMESPACE" \
  --image=curlimages/curl:8.23.0 -- \
  curl -sS "http://$RELEASE-sglang-agg-baseline:8000/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\": \"$MODEL_ID\", \"prompt\": \"The capital of France is\", \"max_tokens\": 32}"
```

## KV cache tiers (skeleton, not built or measured on real hardware yet)

`kvCacheTier.mode` uses the same three names as the vLLM charts (RFC #37, Decision 11), mapped onto SGLang's own hierarchical cache (HiCache):

| `kvCacheTier.mode` | What the chart renders |
| --- | --- |
| `gpu-only` (default) | Nothing: SGLang's own GPU-resident radix cache only |
| `local` | `--enable-hierarchical-cache --hicache-size <kvCacheTier.hicache.sizeGb>`: a second tier in this engine's own host memory ([HiCache design](https://docs.sglang.io/advanced_features/hicache_design.html): L1 GPU, L2 host memory, node-local and owned by one engine) |
| `remote` | Fails to render. SGLang's HiCache documents no Redis/ElastiCache third-tier backend, so this tier stays vLLM-only until that is confirmed |

Unlike the vLLM charts, where `local` and `remote` render identically, `local` here does select something real: the host memory of the engine's own pod. `kvCacheTier.hicache.sizeGb` is required with `local`, because SGLang's own default sizes the host pool at twice the GPU pool, which can silently exceed the pod's memory request; raise `engine.resources.requests.memory` by at least the same amount. `--hicache-size` is counted in units of 10^9 bytes (`python/sglang/srt/mem_cache/pool_host/base.py`). With `engine.replicas` above 1, each replica has its own host tier; nothing is shared between replicas.

## Measure

Run the same load replay and scorer from [`../../_shared/`](../../_shared/) against `http://$RELEASE-sglang-agg-baseline:8000`, with the same trace parameters and SLO as the disaggregated run, and `--gpu-count` set to the number the installation notes print. The load replay drives SGLang with the same pinned `vllm bench serve` client the vLLM examples use, through SGLang's OpenAI-compatible `/v1/completions` endpoint, rather than SGLang's own `sglang.benchmark.serving`; the reason is in [`../../_shared/README.md`](../../_shared/README.md#load-replay). Engine-side panels are in the dashboard [`../../_shared/dashboards/sglang-pd.json`](../../_shared/dashboards/sglang-pd.json).

## Values

| Value | Default | Meaning |
| --- | --- | --- |
| `model.name` | `""` | Hugging Face model repository id. Required; the engine exits with a message until it is set |
| `model.revision` | `""` | Model repository commit or tag; empty is the default branch |
| `model.servedModelName` | `""` | Name clients send as `model`; empty is `model.name` |
| `model.hfTokenSecret.name` / `.key` | `""` / `token` | Secret with a Hugging Face token, for gated models |
| `image.repository` / `.tag` / `.digest` | `lmsysorg/sglang` / `v0.5.23-efa` / pinned | Same image as the disaggregated chart |
| `accelerator.resourceName` | `nvidia.com/gpu` | Extended resource the GPU device plugin advertises |
| `engine.replicas` | `1` | Engines |
| `engine.gpusPerEngine` | `1` | GPUs per engine (`--tp-size`) |
| `engine.scheduler.enableMixedChunk` | `true` | `--enable-mixed-chunk`; part of the tuned baseline |
| `engine.scheduler.chunkedPrefillSize` | `8192` | `--chunked-prefill-size`, always passed; `-1` disables chunked prefill and cannot be combined with `enableMixedChunk` |
| `engine.nodeSelector` | `{}` | Nodes the engines may run on |
| `engine.tolerations` | `[]` | Tolerations, for example for GPU node taints |
| `engine.resources` | 4 CPU, 32Gi requested | CPU and memory; the GPU limit is added from `gpusPerEngine` |
| `engine.extraArgs` / `engine.extraEnv` | `[]` | Extra `sglang.launch_server` arguments and environment variables |
| `engine.port` | `8000` | Engine HTTP port, also serving `/metrics` |
| `engine.shmSizeLimit` | `16Gi` | Size of the memory-backed `/dev/shm` |
| `engine.cacheVolume` | `emptyDir: {}` | Volume for the model download cache, `HOME` and the compile caches |
| `engine.startupTimeoutSeconds` | `1800` | Time allowed for download and load before a restart |
| `engine.podSecurityContext`, `engine.containerSecurityContext` | non-root UID 1000, all capabilities dropped | Security context of the engine pods |
| `service.type` / `.port` | `ClusterIP` / `8000` | Client-facing Service |
| `metrics.enabled` | `true` | `--enable-metrics`, plus the pod labels and annotations for the `sglang` scrape job |
| `kvCacheTier.mode` | `gpu-only` | `local` adds HiCache with a host tier; `remote` fails to render. Skeleton only |
| `kvCacheTier.hicache.sizeGb` | `0` | Host KV pool per engine (`--hicache-size`); required with `local` |
| `kvCacheTier.hicache.extraArgs` | `[]` | Extra HiCache flags, passed unchanged |

## Known issues

- The SGLang image runs as root by default and has no non-root user of its own. The chart runs it as UID 1000 with all capabilities dropped and `HOME` on the cache volume. **Confirmed on real hardware**: the engine reached `Running`/`Ready` under this security context and served a real completion — this UID/capability combination does not block startup at this chart's defaults. Not independently checked: a workload that writes outside `HOME`/`/tmp`.
- SGLang's `/health` generates one token when the engine is idle and takes at least one second, so the probes use a 25-second timeout. A probe failure therefore means the engine could not generate, not only that the process is gone.
- SGLang's OpenAI-compatible server has no authentication in this configuration. The Service is `ClusterIP`; restrict access with a NetworkPolicy if the cluster is shared.
- With the default `emptyDir` cache, every engine pod downloads the weights at start.

## Clean up

```bash
helm uninstall "$RELEASE" -n "$NAMESPACE"
```
