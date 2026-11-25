# vLLM aggregated baseline

This Helm chart serves one model the ordinary way: each vLLM engine runs prefill and decode in the same process, with no KV connector. It is the comparison point for the [prefill/decode disaggregated chart](../disagg-pd/): same pinned image, same model values, same metrics, so that a comparison run on the same hardware changes the layout and nothing else.

vLLM's own scheduler defaults are kept on purpose. Chunked prefill is on by default and running decodes are scheduled ahead of new prefills, which is the tuned aggregated configuration for vLLM; no scheduler flag is needed or set. A claim that disaggregation is better is only evidence against this baseline measured in the same run series, with the same trace and the same SLO.

## Prerequisites

| Requirement | Why |
| --- | --- |
| An EKS cluster with NVIDIA GPU nodes and the NVIDIA device plugin (`nvidia.com/gpu`) | Engines request GPUs as an extended resource |
| Nodes that can pull `vllm/vllm-openai` from Docker Hub and model weights from Hugging Face | The image and the weights are downloaded at start |
| `kubectl` and Helm 3.8 or later on your workstation | Installing the chart |

No EFA device is needed: nothing leaves the engine.

## Deploy

```bash
git clone https://github.com/littlemex/distai-platform.git
cd distai-platform
export NAMESPACE=pd-demo
export RELEASE=agg
export MODEL_ID="${MODEL_ID:?set MODEL_ID to a Hugging Face model repository id}"
helm install "$RELEASE" examples/inference/vllm/agg-baseline \
  --namespace "$NAMESPACE" --create-namespace \
  --set model.name="$MODEL_ID"
kubectl rollout status deployment -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" --timeout=40m
```

To compare with a disaggregated run, give this release the same total number of GPUs (`engine.replicas` x `engine.gpusPerEngine` equal to the prefill plus decode GPUs of the other release) and the same kind of nodes, for example by selecting a node labeled for one of the disaggregated roles with `--set-string 'engine.nodeSelector.distai\.dev/pd-role=prefill'`. Pin `model.revision` on both releases.

## Verify

```bash
kubectl run curl-agg --rm -i --restart=Never -n "$NAMESPACE" \
  --image=curlimages/curl:8.23.0 -- \
  curl -sS "http://$RELEASE-vllm-agg-baseline:8000/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\": \"$MODEL_ID\", \"prompt\": \"The capital of France is\", \"max_tokens\": 32}"
```

## KV cache tiers (real-hardware result, 2026-11-22: `gpu-only` is the only usable tier today)

`kvCacheTier.mode: local` or `remote` adds `LMCacheMPConnector` for a cache tier on top of vLLM's own GPU-resident cache; `local`/`remote` render identically (one static `kvCacheTier.lmcache.mpServerEndpoint`). **Real-hardware verification on this chart (`us-east-1`, `g7.8xlarge` x2, `engine.replicas=2`) found every non-`gpu-only` path broken** — see [`../disagg-pd/README.md`'s own "KV cache tiers" section](../disagg-pd/README.md#kv-cache-tiers-real-hardware-result-2026-11-22-gpu-only-is-the-only-usable-tier-today) for the full table and the two upstream LMCache bugs found (a `local`/POSIX adapter `IndexError`, and a `remote`/`isolated_ipc` `AttributeError` that fatally crashes the engine on any multi-step chunked-prefill request). The cross-node reuse case this chart's own `engine.replicas > 1` was meant to exercise (replica A writes a prefix, replica B on a different node reuses it) was not reached, because registration itself never completed for more than one replica on the default (non-isolated) IPC path, and crashed once a real-size prompt hit the `isolated_ipc` path. **Do not set `kvCacheTier.mode` to anything but `gpu-only` on the currently pinned image.** **Prerequisite this chart does not provide**: an LMCache mp server already reachable at `kvCacheTier.lmcache.mpServerEndpoint`; that server's own endpoint, VPC/subnet-count and TLS requirements if it points at Amazon ElastiCache are this prerequisite's own responsibility (the TLS/AUTH connectivity itself is now confirmed working against a real ElastiCache Valkey replication group — see the linked section — the registration failures above are unrelated to that). Whether a `remote` tier backed by Amazon ElastiCache's distributed KV caching feature needs an EFA device on this chart's own engine pods (not only on the cache nodes) is unconfirmed; the "No EFA device is needed" line in Prerequisites above is about `kvCacheTier.mode=gpu-only`, this chart's own default.

## Measure

Run the same load replay and scorer from [`../../_shared/`](../../_shared/) against `http://$RELEASE-vllm-agg-baseline:8000`, with the same trace parameters and SLO as the disaggregated run, and `--gpu-count` set to the number the installation notes print.

## Values

| Value | Default | Meaning |
| --- | --- | --- |
| `model.name` | `""` | Hugging Face model repository id. Required; the engine exits with a message until it is set |
| `model.revision` | `""` | Model repository commit or tag; empty is the default branch |
| `model.servedModelName` | `""` | Name clients send as `model`; empty is `model.name` |
| `model.hfTokenSecret.name` / `.key` | `""` / `token` | Secret with a Hugging Face token, for gated models |
| `image.repository` / `.tag` / `.digest` | `vllm/vllm-openai` / `v0.34.0-efa` / pinned | Same image as the disaggregated chart |
| `accelerator.resourceName` | `nvidia.com/gpu` | Extended resource the GPU device plugin advertises |
| `engine.replicas` | `1` | Engines |
| `engine.gpusPerEngine` | `1` | GPUs per engine (tensor parallel degree) |
| `engine.nodeSelector` | `{}` | Nodes the engines may run on |
| `engine.tolerations` | `[]` | Tolerations, for example for GPU node taints |
| `engine.resources` | 4 CPU, 32Gi requested | CPU and memory; the GPU limit is added from `gpusPerEngine` |
| `engine.mps` (`.enabled`, `.replicas`) | `false`, `2` | Set `enabled: true` and `replicas` to match this release's own pool's `accelerator.sharingLabel` MPS split if it runs on one; computes a safe `--gpu-memory-utilization` and makes `gpuMemoryUtilization` below fail to render if it exceeds the MPS-aware ceiling. This chart was not the one found crashing under MPS (`../../README.md`'s own "MPS" section) — kept at the same default as `disagg-pd` for one rule a reader of both charts can hold in their head, not because this chart's own real-hardware evidence requires it |
| `engine.gpuMemoryUtilization` | `""` | `""` leaves vLLM's own built-in default alone (unchanged behavior). An explicit value is always honored; combined with `mps.enabled: true` it must be at or below `0.90/mps.replicas` |
| `engine.extraArgs` / `engine.extraEnv` | `[]` | Extra `vllm serve` arguments and environment variables |
| `engine.port` | `8000` | Engine HTTP port, also serving `/metrics` |
| `engine.shmSizeLimit` | `16Gi` | Size of the memory-backed `/dev/shm` |
| `engine.cacheVolume` | `emptyDir: {}` | Volume for the model download cache |
| `engine.startupTimeoutSeconds` | `1800` | Time allowed for download and load before a restart |
| `engine.podSecurityContext`, `engine.containerSecurityContext` | non-root UID 2000, all capabilities dropped | Security context of the engine pods |
| `service.type` / `.port` | `ClusterIP` / `8000` | Client-facing Service |
| `metrics.enabled` | `true` | Pod label and annotations for the `vllm` scrape job |
| `kvCacheTier.mode` | `gpu-only` | `local` or `remote` adds `LMCacheMPConnector`; see "KV cache tiers" above. Skeleton only |
| `kvCacheTier.lmcache.mpServerEndpoint` | `""` | `host:port` of LMCache's own separate mp server; required whenever `mode` is `local` or `remote` |
| `kvCacheTier.lmcache.extraConfig` | `{}` | Merged into `kv_connector_extra_config` as-is; unconfirmed beyond `lmcache.mp.host`/`lmcache.mp.port` |

## Known issues

- vLLM's OpenAI-compatible server has no authentication in this configuration. The Service is `ClusterIP`; restrict access with a NetworkPolicy if the cluster is shared.
- With the default `emptyDir` cache, every engine pod downloads the weights at start.

## Clean up

```bash
helm uninstall "$RELEASE" -n "$NAMESPACE"
```
