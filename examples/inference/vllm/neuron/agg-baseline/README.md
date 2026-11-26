# vLLM aggregated baseline on AWS Trainium (vLLM Neuron plugin)

This Helm chart serves one model the ordinary way on AWS Trainium: each vLLM engine runs prefill and decode in the same process, with no KV connector. It is the comparison point for the [Neuron prefill/decode disaggregated chart](../disagg-pd/): same pinned image, same model values, same metrics, so that a comparison run on the same instance type changes the layout and nothing else. It is the Neuron counterpart of the NVIDIA chart [`../../agg-baseline/`](../../agg-baseline/), with the same value names wherever the concept is the same.

The engines run the [vLLM Neuron plugin](https://github.com/vllm-project/vllm-neuron) `0.29.0.1.2.0` (vLLM `0.29.0`, Neuron SDK `2.33`). vLLM's own scheduler defaults are kept on purpose; no scheduler flag is set. A claim that disaggregation is better is only evidence against this baseline measured in the same run series, with the same trace and the same SLO.

What differs from the NVIDIA chart is the same as for the disaggregated chart (see [its table](../disagg-pd/README.md#what-differs-from-the-nvidia-chart-and-why)), minus everything about the KV connector: the image, `engine.neuronCoresPerEngine` in place of `engine.gpusPerEngine`, a whole-device request of `aws.amazon.com/neuron` = ceil(`neuronCoresPerEngine` / `accelerator.coresPerDevice`), the compile cache `engine.compileCacheVolume` at `VLLM_CACHE_ROOT`, no MPS or memory-fraction values, and `HOME`/`USER` set for the non-root UID. `NEURON_VISIBLE_DEVICES` is never set.

## Prerequisites

| Requirement | Why |
| --- | --- |
| A cell of this platform, which delivers the core add-on [`accel-neuron-device-plugin`](../../../../../gitops/addons/accel-neuron-device-plugin/addon.yaml) (`aws.amazon.com/neuron`) | Engines request Neuron devices as an extended resource |
| A Trainium capacity pool shaped like [`gitops/cells/dp-a19-trn-r3/capacity-pool/trn.yaml`](../../../../../gitops/cells/dp-a19-trn-r3/capacity-pool/trn.yaml) | The method label opts the nodes into the Neuron device plugin. No EFA interface is needed: nothing leaves the engine. To compare with the disaggregated chart, run on one of its two pools instead |
| The toleration `aws.amazon.com/neuron=true:NoSchedule` (`engine.tolerations`) | That pool shape taints its nodes so that only pods requesting the device land there |
| A Hugging Face token with access to the model, for gated models such as `meta-llama/Llama-3.2-1B-Instruct` | The weights are downloaded at start |
| Nodes that can pull from `public.ecr.aws` and Hugging Face, with a root volume large enough for the image (about 6.5 GB compressed; the pool shape above sets `100Gi`) | The image and the weights are downloaded at start |
| `kubectl` and Helm 3.8 or later on your workstation | Installing the chart |

## Deploy

The example matches the disaggregated chart's own example: `meta-llama/Llama-3.2-1B-Instruct`, one NeuronCore per engine, the same `--max-model-len 4096 --max-num-seqs 4`, on the prefill pool's `trn2.3xlarge` nodes. To give this release the same total number of devices as a disaggregated release with one prefill and one decode engine, set `engine.replicas=2`.

```bash
git clone https://github.com/littlemex/distai-platform.git
cd distai-platform
export NAMESPACE=pd-neuron
export RELEASE=aggn
export MODEL_ID=meta-llama/Llama-3.2-1B-Instruct
export POOL=trn-prefill
export HF_TOKEN="${HF_TOKEN:?set HF_TOKEN to a Hugging Face token with access to the model}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic hf-token -n "$NAMESPACE" --from-literal=token="$HF_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
helm install "$RELEASE" examples/inference/vllm/neuron/agg-baseline \
  --namespace "$NAMESPACE" \
  --set model.name="$MODEL_ID" \
  --set model.hfTokenSecret.name=hf-token \
  --set engine.neuronCoresPerEngine=1 \
  --set-string "engine.nodeSelector.karpenter\.sh/nodepool=$POOL" \
  --set-json 'engine.tolerations=[{"key":"aws.amazon.com/neuron","operator":"Equal","value":"true","effect":"NoSchedule"}]' \
  --set-json 'engine.extraArgs=["--max-model-len","4096","--max-num-seqs","4"]'
kubectl rollout status deployment -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" --timeout=40m
```

Pin `model.revision` on both releases for any measurement.

## Verify

```bash
kubectl run curl-aggn --rm -i --restart=Never -n "$NAMESPACE" \
  --labels=app.kubernetes.io/name=load-replay \
  --image=curlimages/curl:8.23.0 -- \
  curl -sS -f "http://$RELEASE-vllm-neuron-agg-baseline:8000/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\": \"$MODEL_ID\", \"prompt\": \"The capital of France is\", \"max_tokens\": 32}"
```

## Measure

Run the same load replay and scorer from [`../../../_shared/`](../../../_shared/) against `http://$RELEASE-vllm-neuron-agg-baseline:8000`, with the same trace parameters and SLO as the disaggregated run, and `--gpu-count` set to the number of Neuron devices the installation notes print.

## Values

| Value | Default | Meaning |
| --- | --- | --- |
| `model.name` | `""` | Hugging Face model repository id. Required; the engine exits with a message until it is set |
| `model.revision` | `""` | Model repository commit or tag; empty is the default branch |
| `model.servedModelName` | `""` | Name clients send as `model`; empty is `model.name` |
| `model.hfTokenSecret.name` / `.key` | `""` / `token` | Secret with a Hugging Face token, for gated models |
| `image.repository` / `.tag` / `.digest` | `public.ecr.aws/neuron/pytorch-inference-vllm-neuronx` / `0.29.0.1.2.0-neuronx-py314-sdk2.33.1-ubuntu26.04` / `sha256:7e44e4f6...` (pinned) | Same image as the disaggregated chart |
| `accelerator.resourceName` | `aws.amazon.com/neuron` | Extended resource the Neuron device plugin advertises, one unit per device |
| `accelerator.coresPerDevice` | `4` | NeuronCores per device; devices per engine = ceil(`neuronCoresPerEngine` / this) |
| `engine.replicas` | `1` | Engines |
| `engine.neuronCoresPerEngine` | `1` | NeuronCores per engine (tensor parallel degree) |
| `engine.nodeSelector` | `{}` | Nodes the engines may run on |
| `engine.tolerations` | `[]` | Tolerations; `aws.amazon.com/neuron=true:NoSchedule` for this platform's Neuron pools |
| `engine.resources` | 4 CPU, 32Gi requested | CPU and memory; the Neuron device limit is added from the values above |
| `engine.extraArgs` / `engine.extraEnv` | `[]` | Extra `vllm serve` arguments and environment variables |
| `engine.port` | `8000` | Engine HTTP port, also serving `/metrics` |
| `engine.shmSizeLimit` | `16Gi` | Size of the memory-backed `/dev/shm` |
| `engine.cacheVolume` | `emptyDir: {}` | Volume for the model download cache (`HF_HOME`) |
| `engine.compileCacheVolume` | `emptyDir: {}` | Volume for the compile cache (`VLLM_CACHE_ROOT`); one per pod, not shared |
| `engine.startupTimeoutSeconds` | `1800` | Time allowed for download, compile and load before a restart |
| `engine.podSecurityContext`, `engine.containerSecurityContext` | non-root UID 2000, all capabilities dropped | Security context of the engine pods |
| `service.type` / `.port` | `ClusterIP` / `8000` | Client-facing Service |
| `metrics.enabled` | `true` | Pod label and annotations for the `vllm` scrape job |
| `networkPolicy.enabled` | `true` | Default-deny ingress, admitting only the shared load-replay driver |
| `networkPolicy.metricsScrapeFrom` | `[]` | Ingress peers allowed to scrape `engine.port` |
| `kvCacheTier.mode` | `gpu-only` | Same mode names as the NVIDIA chart; `gpu-only` renders no KV connector. `local`/`remote` add `LMCacheMPConnector`, unverified on Neuron |
| `kvCacheTier.lmcache.mpServerEndpoint` | `""` | `host:port` of LMCache's own mp server; required whenever `mode` is `local` or `remote` |
| `kvCacheTier.lmcache.extraConfig` | `{}` | Merged into `kv_connector_extra_config` as-is |

## Known issues

- Not run on real hardware yet, not for lack of trying. This is the one chart of the two Neuron charts that the real-hardware attempts actually reached: 3 of 4 attempts stopped earlier, in the verification harness's own setup (fixed, not chart defects); the 4th built the full platform stack with no defect found and installed this chart against the `trn-prefill` pool. Its pod correctly requested `aws.amazon.com/neuron: 1` and Karpenter correctly nominated a `NodeClaim` for it, but EC2's own `CreateFleet` returned `UnfulfillableCapacity` for `trn2.3xlarge` every time, 11 times over 33 minutes, before the attempt's own timeout tore the cell down. The status, the exact events and the real-hardware attempts that found this are kept in the [examples Status table](../../../README.md#status) and [#80](https://github.com/littlemex/distai-platform/issues/80).
- The image is pinned by tag and digest (confirmed against the registry's own v2 manifest API).
- The engines run as UID 2000, a user the image does not define; whether a non-root process can open the Neuron device files is still a real-hardware check, not yet reached (see the [disaggregated chart's Known issues](../disagg-pd/README.md#known-issues)).
- vLLM's OpenAI-compatible server has no authentication in this configuration. The Service is `ClusterIP` and the NetworkPolicy admits only the shared load-replay driver.
- With the default `emptyDir` volumes, every engine pod downloads the weights and compiles the model at start.

## Clean up

```bash
helm uninstall "$RELEASE" -n "$NAMESPACE"
```
