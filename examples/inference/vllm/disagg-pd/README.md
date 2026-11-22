# vLLM prefill/decode disaggregation with NixlConnector

This Helm chart serves one model with prefill and decode disaggregated: prefill engines compute the KV cache of each prompt, decode engines pull that KV cache over NIXL and generate the answer, and a small proxy in front sends each request through both. The two roles run as two Deployments with their own replica count and GPUs per engine, so the prefill:decode ratio is a value, not a fixed 1:1. By default prefill and decode never share a node, and the KV cache moves over libfabric on EFA.

The chart uses vLLM's own disaggregation mechanism unchanged: the `NixlConnector` KV connector and the two-step request flow described in vLLM's [disaggregated prefilling](https://docs.vllm.ai/en/latest/features/disagg_prefill.html) and [NixlConnector usage](https://docs.vllm.ai/en/latest/features/nixl_connector_usage/) documents. vLLM marks this feature as a developer preview; its configuration may change between vLLM releases, which is why the image is pinned.

The aggregated baseline to compare against is [`../agg-baseline/`](../agg-baseline/); the load generator, the scorer and the dashboard are in [`../../_shared/`](../../_shared/).

## How a request flows

```mermaid
sequenceDiagram
  participant C as Client
  participant X as Proxy
  participant P as Prefill engine
  participant D as Decode engine
  C->>X: POST /v1/completions
  X->>P: same request, max_tokens=1, stream=false, kv_transfer_params.do_remote_decode=true
  P-->>X: kv_transfer_params (engine id, handshake host and port, KV block ids)
  X->>D: original request + those kv_transfer_params
  D->>P: NIXL handshake, then KV cache read (libfabric/EFA or UCX)
  D-->>X: streamed tokens
  X-->>C: streamed tokens, unchanged
```

The proxy follows the flow of vLLM's own NixlConnector integration-test proxy. It finds engines by resolving the headless `-prefill` and `-decode` Services (which list ready pods only) and picks one of each round robin per request, so load is balanced per request rather than per TCP connection. If a prefill response carries no `kv_transfer_params`, the proxy returns HTTP 502 instead of letting decode quietly recompute the prompt, and the engines run with `kv_load_failure_policy: fail` for the same reason: a broken KV transfer shows up as failed requests, never as slower but successful ones.

## Placement and transport

Three mechanisms keep the roles apart, each doing a different job:

| Mechanism | What it does | Value |
| --- | --- | --- |
| Node label | Nodes are labeled for one role, for example `distai.dev/pd-role=prefill` or `distai.dev/pd-role=decode` | `placement.nodeSelectorKey` (default `distai.dev/pd-role`) |
| `nodeSelector` | Each role requests nodes with its own label value, unless `placement.sameNodeMeasurement=true` overrides both to `placement.sharedPoolValue` (default `shared`) | `prefill.nodeSelectorValue`, `decode.nodeSelectorValue`, `placement.sameNodeMeasurement`, `placement.sharedPoolValue` |
| Required pod anti-affinity (default) or affinity (same-node measurement), on `kubernetes.io/hostname`, rendered on the **decode** Deployment only | Default: decode never schedules onto a node running a prefill pod of the same release, even if the node labels are wrong. With `sameNodeMeasurement=true` and `enforceAntiAffinity=false`: decode is instead required to schedule onto the *same* node as a prefill pod | `placement.enforceAntiAffinity` (default `true`) |

With `placement.sameNodeMeasurement=false` (default), the two mechanisms above already make same-node impossible — two different pools, decode's own anti-affinity never has anything to trigger on, it is a defense-in-depth backstop. `placement.sameNodeMeasurement=true` switches both roles onto one shared pool (so the admin's `NodePool` behind `placement.sharedPoolValue` must be sized to fit both roles' combined GPU/EFA request on one instance, with `limits` capping it to exactly that one instance, so Karpenter cannot launch a second node for it). Within that shared-pool mode, `placement.enforceAntiAffinity=true` (still the default) turns it into a **fault-injection test**: prefill schedules first, decode's required anti-affinity then has nowhere to go (not a second node — the pool's own cap forbids it; not the same node — the anti-affinity rule forbids it), so decode stays `Pending` with a `FailedScheduling` event naming the anti-affinity rule — proving the backstop itself works, not merely that the default happens not to trigger it. Setting `placement.enforceAntiAffinity=false` in that same shared-pool mode is the actual **same-node measurement cell**: decode's required affinity now pulls it onto prefill's own node instead.

Transport is explicit. With `transport.backend=LIBFABRIC` (the default), both roles get `FI_PROVIDER=efa` and `FI_EFA_USE_DEVICE_RDMA=1` and request `vpc.amazonaws.com/efa` devices. Those two variables do not decide what happens when prefill and decode are on the same host: libfabric's EFA provider then uses its own shared-memory path by default, and the EFA device sees no traffic. `FI_EFA_ENABLE_SHM_TRANSFER` is always rendered explicitly, never left to the library's own default: `transport.forceEfaSameNode=true` sets it to `0`, forcing even a same-host transfer onto the EFA device (see `fi_efa(7)`); the default `false` sets it to `1`, the library's own default value, stated rather than omitted. `forceEfaSameNode=true` only renders when `placement.sameNodeMeasurement=true` (the chart fails to render otherwise, since forcing the same-host path has no effect on a cross-node run). Which path a transfer really took is read from the EFA hardware counters, not inferred from these values; see [Check which path the KV cache took](#check-which-path-the-kv-cache-took).

## Prerequisites

| Requirement | Why |
| --- | --- |
| An EKS cluster with NVIDIA GPU nodes and the NVIDIA device plugin (`nvidia.com/gpu`) | Engines request GPUs as an extended resource |
| The EFA device plugin (`vpc.amazonaws.com/efa`) on those nodes, for the default `LIBFABRIC` backend | Engines request EFA devices; FI_PROVIDER=efa needs one |
| At least one node labeled for each role | The node selectors |
| Nodes that can pull `vllm/vllm-openai` from Docker Hub and model weights from Hugging Face | The image and the weights are downloaded at start |
| `kubectl` and Helm 3.8 or later on your workstation | Installing the chart |

GPU only: neither the vLLM Neuron plugin nor NeuronX Distributed Inference ships a disaggregated prefill/decode path today, so this chart has no Neuron variant.

## Deploy

Clone the repository and set the values for your cluster. `MODEL_ID` is a Hugging Face model repository id that fits on `gpusPerEngine` GPUs of your nodes; `PREFILL_NODE` and `DECODE_NODE` are the names of two GPU nodes.

```bash
git clone https://github.com/littlemex/distai-platform.git
cd distai-platform
export NAMESPACE=pd-demo
export RELEASE=pd
export MODEL_ID="${MODEL_ID:?set MODEL_ID to a Hugging Face model repository id}"
export PREFILL_NODE="${PREFILL_NODE:?set PREFILL_NODE to a GPU node name}"
export DECODE_NODE="${DECODE_NODE:?set DECODE_NODE to another GPU node name}"
```

Label the nodes. On a cluster whose GPU nodes come from Karpenter, put the same label in the template of the NodePool that provisions each role instead, so that new nodes carry it from the start.

```bash
kubectl label node "$PREFILL_NODE" distai.dev/pd-role=prefill --overwrite
kubectl label node "$DECODE_NODE" distai.dev/pd-role=decode --overwrite
```

Install the chart. For a gated model, first create the namespace with `kubectl create namespace "$NAMESPACE"`, store your Hugging Face token in a Secret with `kubectl create secret generic hf-token -n "$NAMESPACE" --from-literal=token="$HF_TOKEN"` and add `--set model.hfTokenSecret.name=hf-token`.

```bash
helm install "$RELEASE" examples/inference/vllm/disagg-pd \
  --namespace "$NAMESPACE" --create-namespace \
  --set model.name="$MODEL_ID"
kubectl rollout status deployment -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" --timeout=40m
```

The installation notes print the in-cluster endpoint and the number of GPUs the release requests, which is the `--gpu-count` the scorer needs.

## Verify

Check that prefill and decode landed on different nodes:

```bash
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide
```

Send one request through the proxy from inside the cluster. The Service is `ClusterIP`, so it is not reachable from outside the cluster.

```bash
kubectl run curl-pd --rm -i --restart=Never -n "$NAMESPACE" \
  --image=curlimages/curl:8.23.0 -- \
  curl -sS "http://$RELEASE-vllm-disagg-pd:8000/v1/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\": \"$MODEL_ID\", \"prompt\": \"The capital of France is\", \"max_tokens\": 32}"
```

The response is an ordinary OpenAI-style completion generated by a decode engine from a KV cache that a prefill engine computed.

## Check which path the KV cache took

The EFA hardware counters show whether a transfer used the EFA device. **Which counter actually
moves depends on which side initiates the transfer, confirmed on real hardware**: this chart sets
`kv_connector: NixlConnector` (`transport.*`'s own rendered value) with `kv_role: kv_both` (this
chart's own default); on a real run with that configuration, the engine's own log shows `Creating
v1 connector with name: NixlPullConnector` (against vLLM `v0.34.0`) — this is one observed log line
showing what vLLM's v1 engine instantiated under this chart's own default configuration, not a
general statement of why `kv_role: kv_both` always leads there. With that connector, decode pulls
KV blocks from prefill, so decode's own `rdma_read_bytes` is the counter that increases, not
`rdma_write_bytes` on either side (that counter stayed `0` throughout a real cross-node run — this
run read `rdma_write_bytes` and `rdma_read_bytes` directly; `rdma_write_recv_bytes` was not read, so
is not itself confirmed flat, only inferred from the same transfer direction). The symmetric,
easier-to-read pair is `tx_bytes` on the prefill node and `rx_bytes` on the decode node (confirmed
equal to each other, byte for byte, on a real run). With the efa-node-exporter scrape job in place,
the dashboard panel "EFA RDMA write bytes per node" plots `node_amazonefa_rdma_write_bytes_total`
and `node_amazonefa_rdma_write_recv_bytes_total` — of those two, only the first is confirmed flat
for this chart's own default connector and role on a real run; read `tx_bytes`/`rx_bytes` or
`rdma_read_bytes` instead (no dashboard panel for these yet; tracked in "Known issues" below).
Without a dashboard, read the counters on each node directly, once before and once after sending
requests (follow the real symlink with `find -L`, or
address the exact `ports/1/hw_counters/` path directly — a plain, non-`-L` `find` on
`/sys/class/infiniband/*` does not descend into it, since that whole tree is reached through a
symlink). List each counter file by name rather than with brace expansion: the debug image's `sh`
is BusyBox ash, which does not expand `{a,b,c}`, so a brace-expanded path is passed through
literally and `cat` fails on it.

```bash
export PREFILL_NODE_DBG="$PREFILL_NODE" DECODE_NODE_DBG="$DECODE_NODE"
for ROLE_NODE in "$PREFILL_NODE_DBG" "$DECODE_NODE_DBG"; do
  kubectl debug "node/$ROLE_NODE" -n "$NAMESPACE" --profile=general --image=curlimages/curl:8.23.0 -i -- \
    sh -c 'for f in /host/sys/class/infiniband/*/ports/1/hw_counters/tx_bytes /host/sys/class/infiniband/*/ports/1/hw_counters/rx_bytes /host/sys/class/infiniband/*/ports/1/hw_counters/rdma_read_bytes /host/sys/class/infiniband/*/ports/1/hw_counters/rdma_write_bytes; do echo "$f = $(cat "$f")"; done'
done
```

`kubectl debug` leaves a `node-debugger-*` pod behind; delete it when you are done:

```bash
kubectl get pods -n "$NAMESPACE" -o name | grep node-debugger | xargs kubectl delete -n "$NAMESPACE"
```

To measure the same-node path on purpose, reinstall with both roles on one node and run the two cells one after the other. The node needs **at least two EFA interfaces**, one allocation per engine pod, not just an EFA-capable instance type: Kubernetes' EFA device plugin hands out one physical interface per allocation and never shares one across two Pods, so a single-network-card instance (every `g7`/`g7e` size below `.48xlarge`, confirmed via `aws ec2 describe-instance-types`) leaves the second pod `Pending` forever with a `FailedScheduling` event naming `vpc.amazonaws.com/efa` — not a chart bug, a real resource-count conflict (found on real hardware, `g7.12xlarge`, 2026-11-20). Use an instance with at least two EFA interfaces (`g7.48xlarge` is the smallest `g7` size with two; card counts vary widely by family — `p5en.48xlarge` has 16, not 2, confirmed via `aws ec2 describe-instance-types`, 2026-11-21) and request one EFA-only interface per network card in the shared pool's `EC2NodeClass` (`capacity-pool`'s `pool.networkInterfaces`, see that chart's README for the exact two-network-card example and how to extend it for an instance with more cards).

```bash
helm upgrade "$RELEASE" examples/inference/vllm/disagg-pd -n "$NAMESPACE" \
  --set model.name="$MODEL_ID" \
  --set placement.sameNodeMeasurement=true \
  --set placement.enforceAntiAffinity=false \
  --set transport.forceEfaSameNode=true
```

**What this comparison actually shows, observed on real hardware (`g7.48xlarge`, 2026-11-20), and what it does not**: with two EFA interfaces, each role's Pod is allocated a *different* physical device (confirmed from each pod's own `rdmap*` interface name) — so `transport.forceEfaSameNode=true` and `=false` produced **identical**, nonzero EFA counter traffic (same byte count, both cases) rather than the one-flat/one-rising contrast an earlier version of this README claimed. That is a measurement, not yet a fully isolated explanation: the likely mechanism is that libfabric's same-host shared-memory bypass is keyed to both endpoints resolving to the *same* EFA device address (never true here, since Kubernetes' exclusive, per-Pod device allocation does not let two separate Pods share one physical EFA interface on any instance type), but a difference in IPC/shared-memory namespace between two separate Pods was not separately ruled out as a contributing factor either. This cell still proves two real things — co-located placement, and that a disaggregated pair on one node still moves real KV bytes over EFA hardware — but it cannot show the shm-vs-forced-EFA contrast Decision 6 of the RFC originally described. Whether both roles sharing one Pod (and so, by construction, one EFA allocation) would reproduce that contrast is plausible but untested; see the RFC ([#37](https://github.com/littlemex/distai-platform/issues/37)), Decision 6 (as amended), for the current status.

## KV cache tiers (real-hardware result, 2026-11-22: `gpu-only` is the only usable tier today)

`kvCacheTier.mode` picks whether LMCache is on at all: `gpu-only` (default, no change) keeps vLLM's own GPU-resident cache only; `local` and `remote` both add `LMCacheMPConnector` (the registered connector name for LMCache's current "mp server" integration — not `LMCacheConnector`, confirmed against vLLM's own connector factory). **`mode` does not actually select a node-local vs. an off-node backend**: `local` and `remote` render identically, both pointing `LMCacheMPConnector` at the same `kvCacheTier.lmcache.mpServerEndpoint` — one static value, rendered the same way into every Pod, which run on different nodes by Decision 3. This chart does not deploy, detect or enforce any particular topology for that endpoint.

**Real-hardware verification, `us-east-1`, `g7.8xlarge` x2, the pinned image's own bundled LMCache (v0.5.7.post1), ahead of the p5en Capacity Block**: every path tried hit a genuine blocking defect, and `gpu-only` is the only tier this platform can recommend today.

| Path | Result |
| --- | --- |
| `local` (an LMCache mp server with a `nixl_store`/`POSIX` L2 adapter, one per node) | Broken: `backend_params` values must all be strings (an undocumented NIXL binding requirement — passing `file_size` as a JSON integer raises `TypeError` in `nixl_cu13`'s own `createBackend`), and even once fixed, `NixlStoreL2Adapter.__init__` raises `IndexError: list index out of range` inside `get_xfer_descs` before KV-cache registration is ever reached |
| `remote`, one shared mp server Deployment, default (non-isolated) IPC mode | `register_kv_caches` hands the mp server a CUDA IPC handle onto the engine's own GPU-resident tensors (`torch.UntypedStorage._new_shared_cuda`); CUDA IPC handles are host-local, so registration only succeeds for whichever replica happens to land on the SAME node as the mp server by scheduling chance — every other replica times out after 300s (`ConnectionError: LMCache server did not respond to register_kv_caches within 300.0s`) with the mp server's own log showing `CUDA_ERROR_MAP_FAILED` |
| `remote`, per-node mp server DaemonSet (the corrected topology), default IPC mode | Same CUDA IPC failure even when co-located on the same node: Kubernetes Pods do not share an IPC namespace by default, so `cuIpcOpenEventHandle` still fails between two separate containers — would need `hostIPC: true` on both sides, which this platform rejects as a multi-tenancy regression (#22: a per-team isolation boundary, not an opt-in default) |
| `remote`/`local`, `--isolated-ipc` (LMCache's own, official, hostIPC-avoiding mode — set the mp server's own CLI flag and `kvCacheTier.lmcache.extraConfig.lmcache.mp.isolated_ipc: true`) | Starts clean for a short, single-scheduler-step prompt (confirmed: both replicas `Running`/`Ready`, `RESTARTS=0`), but **crashes the engine fatally** on any prompt long enough to need more than one chunked-prefill step — `AttributeError: 'CachedRequestData' object has no attribute 'resumed_req_ids'` inside `lmcache_mp_connector.py`'s own `_process_cached_requests`, a version mismatch between this pinned LMCache release and this pinned vLLM release's own internal scheduler types |

The RESP/Amazon ElastiCache question Decision 11 of the RFC left open (whether LMCache's RESP adapter's TLS behavior matches what ElastiCache needs) got a real, positive, narrower answer along the way: against a real `cache.t3.micro` Valkey replication group with `TransitEncryptionEnabled=true` and an AUTH token, the mp server's own RESP L2 adapter connected and authenticated cleanly (`Created RESP L2 adapter: <endpoint>:6379`, no reconnect/auth-error lines) — the TLS gap is closed, but it does not matter while every registration path above is itself broken.

**Security note, since a `hostIPC: true` patch was tried and reverted mid-investigation, reviewed by Fable 5.2 and found incomplete on the first draft**: do not default any future fix for this to `hostIPC`. Its blast radius is the whole host IPC namespace — every host process and every other Pod that also joins that namespace on that node, not narrowly "the two Pods that need to talk to each other" (an earlier draft of this note understated that scope). This is a direct conflict with this platform's own per-team isolation decision (#22). LMCache's own `--isolated-ipc`/`lmcache.mp.isolated_ipc` mode exists specifically to avoid this and should be preferred if a future fix revisits this tier, once the scheduler-compatibility crash above is fixed upstream; any chart knob that still needs `hostIPC` must default to off and be an explicit, documented opt-in, never a chart default. **This platform has no admission control (Pod Security Admission, Kyverno or equivalent) that actually rejects `hostIPC`/`hostPID`/`privileged`/`hostPath` today — that gap is still open**, confirmed by the fact that nothing blocked the ad-hoc `hostIPC: true` test patch itself; see `capacity-pool/README.md`'s own "GPU sub-device sharing (MPS)" section for a second, separate, already-shipped feature (NVIDIA's own MPS control daemon) that renders `hostPID: true`/`privileged: true` by upstream design, confirming the same gap independently.

**Whether a different LMCache/vLLM version pairing avoids the `resumed_req_ids` crash, checked against upstream sources rather than tried on hardware (2026-11-22)**: the crash is already fixed upstream — `LMCache/LMCache` commit [`f463aeb213`](https://github.com/LMCache/LMCache/commit/f463aeb213) ("[Bugfix] Handle cached steps without legacy resume IDs in the vLLM MP connector", `#6457`, merged 2026-11-09) changes the direct attribute access to `getattr(cached_reqs, "resumed_req_ids", ())`, and this commit is confirmed (GitHub's own compare API) to be an ancestor of LMCache `v0.5.8rc1` (released 2026-11-13) and therefore of `v0.5.8rc2`/`v0.5.8rc3` too. **But no published `vllm/vllm-openai` image can reach it**: `vllm-project/vllm`'s own `requirements/kv_connectors.txt` on `main` still pins `lmcache == 0.5.7.post1` as of this check (fetched 2026-11-22) — every `-efa` image vLLM publishes, including today's `efa-nightly` tags built fresh from `main` every day, bundles that same pinned, pre-fix LMCache release regardless of which vLLM commit the rest of the image is built from. There is therefore no image/tag this chart could switch to today that would avoid the crash; the fix exists, but only on LMCache's own unreleased-into-any-vLLM-image side of the pairing. Filed as upstream findings 16/17 in [#49](https://github.com/littlemex/distai-platform/issues/49). SGLang's own HiCache still has no confirmed Redis/ElastiCache backend, independent of the above — this tiering stays vLLM-only.

## Measure

Use the in-cluster load replay and the scorer in [`../../_shared/`](../../_shared/) against `http://$RELEASE-vllm-disagg-pd:8000`, then run the same trace against the [aggregated baseline](../agg-baseline/) on the same hardware. A comparison is only meaningful when the model revision, precision, hardware, total GPU count, vLLM version and the replayed trace are the same on both sides; pin `model.revision` for any measurement.

## Values

| Value | Default | Meaning |
| --- | --- | --- |
| `model.name` | `""` | Hugging Face model repository id. Required; the engines exit with a message until it is set |
| `model.revision` | `""` | Model repository commit or tag; empty is the default branch |
| `model.servedModelName` | `""` | Name clients send as `model`; empty is `model.name` |
| `model.hfTokenSecret.name` / `.key` | `""` / `token` | Secret with a Hugging Face token, for gated models |
| `image.repository` / `.tag` / `.digest` | `vllm/vllm-openai` / `v0.34.0-efa` / pinned | Engine and proxy image; the `-efa` variant is built with vLLM's KV connectors and the AWS EFA userspace |
| `accelerator.resourceName` | `nvidia.com/gpu` | Extended resource the GPU device plugin advertises |
| `placement.nodeSelectorKey` | `distai.dev/pd-role` | Node label key that tells the roles apart |
| `placement.sameNodeMeasurement` | `false` | `true` targets both roles' `nodeSelector` at `placement.sharedPoolValue` instead of their own `nodeSelectorValue` |
| `placement.sharedPoolValue` | `shared` | The pool value both roles target when `sameNodeMeasurement=true` |
| `placement.enforceAntiAffinity` | `true` | `false` swaps decode's required anti-affinity (against prefill) for a required affinity (toward prefill) — only meaningful combined with `sameNodeMeasurement=true` |
| `placement.tolerations` | `[]` | Tolerations for both roles, for example for GPU node taints |
| `transport.backend` | `LIBFABRIC` | NIXL backend, `LIBFABRIC` or `UCX` |
| `transport.forceEfaSameNode` | `false` | `true` sets `FI_EFA_ENABLE_SHM_TRANSFER=0` on both roles (else explicitly `1`); requires `LIBFABRIC` and `placement.sameNodeMeasurement=true`. Observed to have no effect on real hardware under this chart's two-Pod model (see "Known issues"), likely because each role always gets its own physical EFA interface there |
| `transport.efaResourceName` | `vpc.amazonaws.com/efa` | Extended resource the EFA device plugin advertises |
| `transport.sideChannelPort` | `5600` | NIXL handshake port (`VLLM_NIXL_SIDE_CHANNEL_PORT`); the host is the pod IP |
| `transport.kvLoadFailurePolicy` | `fail` | `fail` or `recompute` when decode cannot load a transferred KV cache |
| `transport.extraConnectorConfig` | `{}` | Extra keys for `kv_connector_extra_config` |
| `prefill.replicas`, `decode.replicas` | `1`, `1` | Engines per role |
| `prefill.gpusPerEngine`, `decode.gpusPerEngine` | `1`, `1` | GPUs per engine (tensor parallel degree) |
| `prefill.efaDevices`, `decode.efaDevices` | `1`, `1` | EFA devices per engine pod; at least 1 with `LIBFABRIC` |
| `prefill.nodeSelectorValue`, `decode.nodeSelectorValue` | `prefill`, `decode` | Label value each role selects |
| `prefill.extraNodeSelector`, `decode.extraNodeSelector` | `{}` | Additional node selector terms per role |
| `prefill.extraArgs`, `decode.extraArgs` | `[]` | Extra `vllm serve` arguments per role |
| `prefill.extraEnv`, `decode.extraEnv` | `[]` | Extra environment variables per role |
| `prefill.resources`, `decode.resources` | 4 CPU, 32Gi requested | CPU and memory; GPU and EFA limits are added from the values above |
| `engine.port` | `8000` | Engine HTTP port, also serving `/metrics` |
| `engine.shmSizeLimit` | `16Gi` | Size of the memory-backed `/dev/shm` |
| `engine.cacheVolume` | `emptyDir: {}` | Volume for the model download cache |
| `engine.podSecurityContext`, `engine.containerSecurityContext` | non-root UID 2000, all capabilities dropped | Security context of the engine pods |
| `engine.startupTimeoutSeconds` | `1800` | Time allowed for download and load before a restart |
| `proxy.replicas` | `1` | Proxy pods |
| `service.type` / `.port` | `ClusterIP` / `8000` | Client-facing Service in front of the proxy |
| `metrics.enabled` | `true` | Pod label and annotations for the `vllm` scrape job |
| `kvCacheTier.mode` | `gpu-only` | `local` or `remote` stacks `LMCacheMPConnector` onto the mandatory `NixlConnector` via `MultiConnector`; see "KV cache tiers" above. Skeleton only, not built or measured on real hardware yet |
| `kvCacheTier.lmcache.mpServerEndpoint` | `""` | `host:port` of LMCache's own separate mp server; required whenever `mode` is `local` or `remote` (both render identically), fails to render otherwise |
| `kvCacheTier.lmcache.extraConfig` | `{}` | Merged into `kv_connector_extra_config` as-is; unconfirmed beyond `lmcache.mp.host`/`lmcache.mp.port` |

## Known issues

- vLLM documents NixlConnector as a developer preview. The chart is tested against the pinned image only; another vLLM version may need a different connector configuration.
- vLLM's OpenAI-compatible server has no authentication in this configuration. The Services are `ClusterIP`; any pod in the cluster that can reach them can send requests. Restrict access with a NetworkPolicy if the cluster is shared.
- With the default `emptyDir` cache, every engine pod downloads the weights at start. Point `engine.cacheVolume` at a persistent volume to avoid that.
- The engine containers run as the vLLM image's non-root user (UID 2000, GID 0) with all Linux capabilities dropped and privilege escalation disabled. EFA memory registration then relies on the node's locked-memory limit rather than a capability; if your nodes need `IPC_LOCK` for it, add the capability through `engine.containerSecurityContext`.
- One proxy pod is a single point of failure for the endpoint. Raise `proxy.replicas` for anything beyond measurement.
- `transport.forceEfaSameNode` does not show a shm-vs-forced-EFA contrast under `placement.sameNodeMeasurement=true`: both values produce identical EFA traffic once each role has its own physical EFA interface, which is the only way two separate Pods can be co-located at all (confirmed on real hardware, see "Check which path the KV cache took" above). It still correctly forces `FI_EFA_ENABLE_SHM_TRANSFER=0` when set, which is as far as this chart's own contract on the value goes.
- `_shared/dashboards/vllm-pd.json`'s own "EFA RDMA write bytes per node" panel only plots the write-side counters, which stay flat for this chart's own default connector and role (`NixlPullConnector`, see "Check which path the KV cache took" above). No panel for the read-side counters (`tx_bytes`/`rx_bytes`/`rdma_read_bytes`) exists yet; add one before relying on this dashboard to show a disaggregated run's own EFA traffic.
- `placement.sameNodeMeasurement=true` sets the roles' `strategy.type` to `Recreate` (brief downtime on every `helm upgrade` in that mode) instead of the default rolling update, because the shared pool has no spare GPU/EFA capacity for a surge pod to land on while the old one is still running. This only applies in `sameNodeMeasurement` mode; the default (two separate pools) keeps `RollingUpdate`.

## Clean up

```bash
helm uninstall "$RELEASE" -n "$NAMESPACE"
kubectl label node "$PREFILL_NODE" distai.dev/pd-role-
kubectl label node "$DECODE_NODE" distai.dev/pd-role-
kubectl delete namespace "$NAMESPACE"
```
