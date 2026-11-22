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

## KV cache tiers (skeleton, not built or measured on real hardware yet)

`kvCacheTier.mode: local` or `remote` adds `LMCacheMPConnector` (the registered connector name for LMCache's current "mp server" integration, not `LMCacheConnector`; no `MultiConnector` needed here, since this chart has no other KV connector to stack it with) for a cache tier on top of vLLM's own GPU-resident cache. **`mode` does not actually select between a node-local and an off-node backend**: `local` and `remote` render **identically**, both pointing `LMCacheMPConnector` at the same `kvCacheTier.lmcache.mpServerEndpoint` — one static value rendered into every replica. With `engine.replicas > 1` this is the same static value dialed by every replica, which is this aggregated baseline's own way to get cross-replica prefix reuse that a bigger single-process cache cannot give it — but the chart itself does not deploy, detect or enforce any particular topology behind that one endpoint; whichever backend the one external mp server's own adapter actually uses, genuinely node-local or shared, is that process's own property, not something `mode` tells apart or enforces. **Prerequisite this chart does not provide**: an LMCache mp server already reachable at `kvCacheTier.lmcache.mpServerEndpoint`; that server's own endpoint, VPC/subnet-count and TLS requirements if it points at Amazon ElastiCache are this prerequisite's own responsibility. See [`../disagg-pd/README.md`'s own "KV cache tiers" section](../disagg-pd/README.md#kv-cache-tiers-skeleton-not-built-or-measured-on-real-hardware-yet) for what is and is not confirmed — the same caveats apply here, including that vLLM's own KV-event publisher has no visibility into anything LMCache holds (which under-counts reuse for the EPP's own scoring, rather than blocking a hit on this shared tier). Whether a `remote` tier backed by Amazon ElastiCache's distributed KV caching feature needs an EFA device on this chart's own engine pods (not only on the cache nodes) is unconfirmed; the "No EFA device is needed" line in Prerequisites above is about `kvCacheTier.mode=gpu-only`, this chart's own default.

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
