# Inference Examples

Self-contained references for serving models on an EKS cluster. Each example is deployed with `helm` or `kubectl` directly and does not depend on this repository's GitOps delivery; the cluster only has to provide the GPU and EFA device plugins and node labels the example's README lists. Examples are grouped by serving engine, and each one has its own README with prerequisites, copy-paste instructions and known issues.

| Engine | Example | Description |
| --- | --- | --- |
| [`vllm`](vllm/) | [`disagg-pd`](vllm/disagg-pd/) | Prefill/decode disaggregated serving with vLLM's NixlConnector over libfabric/EFA, a prefill-then-decode proxy, a free prefill:decode ratio, and prefill and decode kept on different nodes by default |
| [`vllm`](vllm/) | [`disagg-pd-llmd`](vllm/disagg-pd-llmd/) | The same prefill and decode engines as `disagg-pd`, routed by the llm-d router instead of the proxy: a Gateway API `HTTPRoute` to an `InferencePool`, llm-d's Endpoint Picker choosing a prefill and a decode pod per request, and a routing sidecar in each decode pod. Run on real hardware, working end to end (see Status) |
| [`vllm`](vllm/) | [`agg-baseline`](vllm/agg-baseline/) | Aggregated vLLM serving with vLLM's default scheduler, the baseline the disaggregated layout is compared against on the same hardware |
| [`sglang`](sglang/) | [`disagg-pd`](sglang/disagg-pd/) | Prefill/decode disaggregated serving with SGLang's own transfer backends (NIXL over libfabric/EFA by default, or Mooncake), SGLang's own router finding both roles through the Kubernetes API, and the same placement values as the vLLM chart |
| [`sglang`](sglang/) | [`agg-baseline`](sglang/agg-baseline/) | Aggregated SGLang serving with mixed chunked prefill and an explicit chunk size, the tuned baseline for the SGLang disaggregated layout |

Shared measurement tools used by every example:

| Tool | Description |
| --- | --- |
| [`_shared/load-replay`](_shared/load-replay/) | In-cluster, open-loop Poisson load with `vllm bench serve` as a Kubernetes Job, rejecting runs whose client fell behind and snapshotting pods before and after; the same client drives the vLLM and the SGLang examples |
| [`_shared/scorer`](_shared/scorer/) | Scores saved per-request results against an explicit joint SLO: TTFT limit, longest inter-token gap limit, share of planned requests meeting both, and goodput per GPU including drain |
| [`_shared/dashboards`](_shared/dashboards/) | Grafana dashboards for vLLM and SGLang prefill/decode serving (KV transfer, SGLang's per-role disaggregation queues, EFA counters and scored goodput), with the scrape jobs they read |

How to measure with them is described in [`_shared/README.md`](_shared/README.md).

## Status

| Example | Built | Run on real hardware |
| --- | --- | --- |
| [`vllm/disagg-pd`](vllm/disagg-pd/) (hand-written proxy) | Yes | Yes (the RFC, [#37](https://github.com/littlemex/distai-platform/issues/37), follow-up issue B) |
| [`vllm/agg-baseline`](vllm/agg-baseline/) | Yes | Yes (follow-up issue B) |
| [`vllm/disagg-pd-llmd`](vllm/disagg-pd-llmd/) (llm-d router: Gateway API, `InferencePool`, EPP) | Yes: chart, README and static checks | Yes, working end to end. A first round found the Gateway, `HTTPRoute`, `InferencePool` and EPP all reaching a healthy, correctly-resolved state, but a real request returning `500` (the Gateway implementation's own data plane failing to reach the EPP's `ext_proc` endpoint); root-caused and fixed (a TLS/plaintext transport mismatch between the administrator's own Gateway-implementation configuration and the EPP's own default TLS-serving behavior — fixed on the Gateway-implementation side, not in this chart). A follow-up round sent a real request through the Gateway, got back a real completion, and confirmed the EPP split it across the prefill and decode profiles two ways: its own `llm_d_epp_disagg_decision_total{decision_type="prefill-decode"}` counter, and its own per-request debug log (both profiles run, ending in one `"Request handled"` line) — see [#37](https://github.com/littlemex/distai-platform/issues/37) for the exact evidence |
| [`sglang/disagg-pd`](sglang/disagg-pd/) | Yes | Yes (light-tier two-node cell; see [#37](https://github.com/littlemex/distai-platform/issues/37)). A follow-up round also confirmed the EFA transfer symmetric on both nodes (prefill's `tx_bytes`/`rdma_write_bytes` match decode's `rx_bytes`/`rdma_write_recv_bytes`, byte for byte) |
| [`sglang/agg-baseline`](sglang/agg-baseline/) | Yes | Yes (same cell) |
| [`_shared/dashboards/sglang-pd.json`](_shared/dashboards/sglang-pd.json) | Yes | Not yet fed by a real SGLang run in this round: this round's Prometheus check (see `vllm/agg-baseline`'s own Status) scraped a vLLM engine only. SGLang's own `/metrics` was not inspected, and `sglang-pd.json`'s panels were not opened against a real Grafana |

`tests/0.static.sh` covers `vllm/disagg-pd-llmd` and, as of this round, both SGLang charts' own
`helm lint`/`helm template`/kubeconform (the placement/transport values-contract checks that
already cover the vLLM charts do not cover the SGLang charts yet — a separate, deeper follow-up).
All five combinations above now work end to end on real hardware.

## MPS (GPU sub-device sharing), round 2: label-design fix and the 4 forms (real hardware, `us-east-1`, `g7.8xlarge`/`g7.48xlarge`, 2026-11-22)

A prior round confirmed the MPS mechanism itself (`accelerator.sharingLabel`, see
`gitops/charts/capacity-pool/README.md`) but left the actual label management broken: NVIDIA's
`mps-control-daemon` DaemonSet needs a second node label (`nvidia.com/mps.capable=true`) this
platform had no way to set except by hand after the node joined, and a later NodePool edit (read
as Karpenter drift) silently destroyed that label on the replacement node before it could be
relabeled. `capacity-pool`'s new `accelerator.mpsLabel` field closes this by rendering the label
into the NodePool's own node template instead, alongside `sharingLabel`.

**Drift-survival, confirmed on real hardware.** Forced an actual Karpenter-driven node replacement
on an MPS-opted-in pool (`gpu-shared`, `g7.8xlarge`) by bumping `pool.rootVolumeSizeGi`. The
replacement node (`ip-10-0-100-212`, confirmed different from the original `ip-10-0-100-89` by
name) carried both `nvidia.com/mps.capable=true` and `nvidia.com/device-plugin.config=mps-2` with
zero manual steps, and `nvidia.com/gpu` allocatable read `2` on it immediately — the drift no
longer destroys the label. One rough edge observed at the moment of replacement: the
`mps-control-daemon` Pod on the new node showed `1/2 Ready`, `Error`, 2 restarts, 44s after
creation; by the time real workloads used that same node a few minutes later (T0/T1 below, both
`RESTARTS=0`), the daemon had stabilized — consistent with the already-documented upstream
config-watcher-sidecar-restarts-after-relabel oddity (`capacity-pool/README.md`), not a functional
regression.

**The 4 forms.** All four cells target this one drift-replaced node/pool pair unless noted.

| Form | Engine | Result |
| --- | --- | --- |
| (a) Aggregated, 1 GPU x 2 replicas | vLLM | Confirmed: both replicas on the same node (`ip-10-0-100-212`), `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=3.997`, TTFT p50/p90/p99 = 8.6/11.1/18.9 ms |
| (a) Aggregated, 1 GPU x 2 replicas | SGLang | Confirmed: both replicas on the same node, `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=4.005`, TTFT p50/p90/p99 = 9.6/66.7/92.8 ms |
| (b) Same-node prefill+decode colocate | vLLM | **Not confirmed this round.** The first attempt used `placement.sameNodeMeasurement=true` without also setting `placement.enforceAntiAffinity=false`, which (per this chart's own values.yaml/NOTES.txt) renders the chart's own documented "fault-injection shape" (required anti-affinity) instead of colocation — decode stayed `Pending` for the full 12-minute timeout, exactly as the chart's own NOTES.txt predicts for that combination. A same-day retry with the correct flag (`enforceAntiAffinity=false`) still left decode `Pending` with `node=<none>` for its own 12-minute window — most likely racing a lingering GPU allocation from the just-uninstalled first attempt (the retry's own wait only checked that the Helm release was gone, not that the Pod's GPU allocation had actually been released by the device plugin), not re-investigated further within this round's time box. A targeted round-3 retry, with an explicit per-deployment rollout check and a longer settle window, is in progress/pending — see the Known issues table below for the final call |
| (b) Same-node prefill+decode colocate | SGLang | Confirmed (on the retry, with `enforceAntiAffinity=false`): decode, prefill and the router all on the same node (`ip-10-0-100-212`), `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=4.001`, TTFT p50/p90/p99 = 18.2/22.8/146.2 ms |
| (c) 2-node disaggregated over EFA, MPS-shared prefill | vLLM | **Failed, root cause not yet closed.** `decode` (separate `g7.8xlarge` node) reached `Running`/`Ready`; both `prefill` replicas (same `g7.48xlarge` MPS-shared node) crash-looped (`0/1 Running`, 4 restarts in 10 minutes) — the deployment never rolled out. A round-3 retry with full container-log capture on the crash is in progress/pending — see the Known issues table below |
| (c) 2-node disaggregated over EFA, MPS-shared prefill | SGLang | Functionally confirmed: `decode` (separate `g7.8xlarge` node) and both `prefill` replicas (same `g7.48xlarge` MPS-shared node) all `Running`/`Ready`, `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=1.338`. **Two things this round could not confirm, stated precisely rather than assumed**: (1) the EFA `hw_counters` diagnostic (`rdma_write_bytes`/`rdma_read_bytes` under `/sys/class/infiniband/*/ports/1/hw_counters/`) returned empty for every pod, before and after load — a diagnostic-command problem this round did not have time to root-cause, not evidence either way that EFA traffic did or did not move; (2) no GPU UUID was captured for either prefill replica, so whether the two MPS clients actually landed on the SAME physical GPU (true MPS sharing) or on two of the node's 8 physical GPUs (same node, no sharing, still functionally correct) is not distinguished by any check this round ran — a real gap in the test's own evidence, found by Fable 5.2 review, not yet closed |

**SGLang HiCache cold/warm retry (round 2).** Cold pass confirmed again (`exit-code=0`); the warm
pass (same prefix set, re-applying the `load-replay` Job under the same name after deleting the
prior one) did not produce a result this round (`exit-code` empty) — the retry's own fix (wait for
the deleted Job's Pod to actually disappear, not just the Job object, before reapplying) is being
tried in round 3; see the Known issues table below for the final call.

**Known issues, to be resolved by the end of this investigation (not left silently open):**

| # | What | Status |
| --- | --- | --- |
| 1 | vLLM same-node MPS colocate (form (b)) | Round 3 in progress |
| 2 | vLLM 2-node MPS-disagg-over-EFA prefill crash loop (form (c)) | Round 3 in progress, full logs being captured |
| 3 | SGLang HiCache warm pass | Round 3 in progress |
| 4 | EFA byte-counter evidence for form (c) | Diagnostic command bug, not yet fixed |
| 5 | GPU-UUID evidence that MPS clients share one physical GPU in form (c) | Not captured this round, no fix attempted yet |

## Conventions

- Node roles are told apart by a node label, `distai.dev/pd-role` by default, and every chart lets you change the key.
- A disaggregated layout is only compared with an aggregated baseline measured on the same hardware, with the same model revision, trace and SLO.
- Images are pinned by tag and digest. Services are `ClusterIP`; nothing is exposed outside the cluster by default.
- The disaggregated examples are GPU only: neither the vLLM Neuron plugin nor NeuronX Distributed Inference ships a disaggregated prefill/decode path today, and SGLang's disaggregation path has no Neuron variant.
- The vLLM and SGLang charts share their value names wherever the two engines share a concept (`placement.*`, `prefill.*`, `decode.*`, `engine.*`, `kvCacheTier.mode`, `metrics.enabled`); they differ only where the engines do (`transport.*`, and the router in front of the roles).
