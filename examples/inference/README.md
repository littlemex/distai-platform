# Inference Examples

Self-contained references for serving models on an EKS cluster. Each example is deployed with `helm` or `kubectl` directly and does not depend on this repository's GitOps delivery; the cluster only has to provide the GPU and EFA device plugins and node labels the example's README lists -- **except `vllm/disagg-pd-llmd`**, which additionally needs the Gateway API and Inference Extension CRDs and a Gateway implementation installed by the cluster administrator (see that chart's own README Prerequisites). Examples are grouped by serving engine, and each one has its own README with prerequisites, copy-paste instructions and known issues.

**Naming note**: `vllm/disagg-pd` is a hand-written prefill-then-decode proxy that this directory tree built first; `vllm/disagg-pd-llmd` is the RFC's own Decision 2 adoption for vLLM (the llm-d/Gateway API router). The RFC ([#37](https://github.com/littlemex/distai-platform/issues/37)) Decision 1 names one vLLM directory and does not anticipate this split; both charts stay as they are named today rather than renaming the hand-written proxy out from under a reader already linking to it, and this note -- plus [#37](https://github.com/littlemex/distai-platform/issues/37)'s own thread -- is the record of why two directories exist where the RFC's tree lists one.

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

## MPS (GPU sub-device sharing), round 2: label-design fix and the 3 forms (real hardware, `us-east-1`, `g7.8xlarge`/`g7.48xlarge`, 2026-11-22)

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
longer destroys the label. What is, and is not, independently re-confirmed: the node's own labels
and allocatable count were read directly after the replacement; the `mps-control-daemon` Pod's own
health was NOT re-observed at that same moment — it showed `1/2 Ready`, `Error`, 2 restarts, 44s
after creation, a real, observed state (not the "config-watcher sidecar restarts after relabel,
main container stays healthy" oddity `capacity-pool/README.md` documents elsewhere, since no
relabel happened here and the Pod itself reported `Error`, not just a sidecar restart). A real
workload was served from this same node a few minutes later with `RESTARTS=0` (T0/T1 below), which
is evidence the daemon had become healthy by then, but that inference stands in place of a direct
re-read of the daemon Pod's own status at a later timestamp — not yet done.

**The 3 forms, each tried on both engines.** All cells target this one drift-replaced node/pool pair unless noted.

| Form | Engine | Result |
| --- | --- | --- |
| (a) Aggregated, 1 GPU x 2 replicas | vLLM | Confirmed: both replicas on the same node (`ip-10-0-100-212`), `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=3.997`, TTFT p50/p90/p99 = 8.6/11.1/18.9 ms |
| (a) Aggregated, 1 GPU x 2 replicas | SGLang | Confirmed: both replicas on the same node, `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=4.005`, TTFT p50/p90/p99 = 9.6/66.7/92.8 ms |
| (b) Same-node prefill+decode colocate | vLLM | **Blocked by a real, reproducible defect (proximate cause found in round 3, not fully explained -- see below), not a scheduling issue.** Both the fault-injection-shape attempt (missing `enforceAntiAffinity=false`) and the corrected retry put prefill+decode on one MPS-shared GPU; in round 3's retry both containers reached `CrashLoopBackOff` with `successful_requests=0/40`, `failed_requests=40/40` |
| (b) Same-node prefill+decode colocate | SGLang | Confirmed (with `enforceAntiAffinity=false`): decode, prefill and the router all on the same node (`ip-10-0-100-212`), `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=4.001`, TTFT p50/p90/p99 = 18.2/22.8/146.2 ms |
| (c) 2-node disaggregated over EFA, MPS-shared prefill | vLLM | **Blocked by the same proximate cause as (b), not fully explained -- see below.** `decode` (separate `g7.8xlarge` node) reached `Running`/`Ready`; both `prefill` replicas (same `g7.48xlarge` MPS-shared node) crash-looped in both round 2 and round 3 |
| (c) 2-node disaggregated over EFA, MPS-shared prefill | SGLang | Functionally confirmed: `decode` (separate `g7.8xlarge` node) and both `prefill` replicas (same `g7.48xlarge` MPS-shared node) all `Running`/`Ready`, `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=1.338`. **Two things this investigation could not confirm, stated precisely rather than assumed, and not yet closed**: (1) the EFA `hw_counters` diagnostic (`rdma_write_bytes`/`rdma_read_bytes` under `/sys/class/infiniband/*/ports/1/hw_counters/`) returned empty for every pod, before and after load, in round 2 — a diagnostic-command problem, not re-attempted in round 3 to stay inside the 3-hour real-hardware time budget; (2) no GPU UUID was captured for either prefill replica, so whether the two MPS clients actually landed on the SAME physical GPU (true MPS sharing) or on two of the node's 8 physical GPUs (same node, no sharing, still functionally correct) is not distinguished by any check this investigation ran — a real gap in the test's own evidence, found by Fable 5.2 review |

### Proximate cause for vLLM forms (b) and (c), found in round 3 -- NOT yet a full explanation (see the open contradiction below)

Forms (b) and (c)'s vLLM crashes show the **same traceback**
(`vllm/v1/worker/gpu_worker.py`'s `request_memory`):

```text
ValueError: Free memory on device cuda:0 (15.72/31.38 GiB) on startup is less than desired GPU
memory utilization (0.92, 28.87 GiB). Decrease GPU memory utilization or reduce GPU memory used
by other processes.
```

vLLM's own startup check computes its memory budget as `gpu_memory_utilization * TOTAL physical
device memory` (here, `0.92 * 31.38 GiB ≈ 28.87 GiB`) and refuses to start unless that much is
free; the `15.72 GiB` it found free is close to (not exactly) half of `31.38 GiB`, matching
`capacity-pool/README.md`'s own confirmed MPS pinned-memory-limit log line
(`set_default_device_pinned_mem_limit 0 16311M` ≈ `15.93 GiB`) within the rounding these two
numbers carry. This is a confirmed, real, reproducible proximate cause for (b) and (c): two vLLM
processes, each wanting `0.92 * 31.38 GiB` of device memory (confirmed from the traceback itself,
not derived from any value this platform's own charts set — neither `vllm/agg-baseline` nor
`vllm/disagg-pd` sets `gpu_memory_utilization`/`--gpu-memory-utilization` anywhere in `values.yaml`
or any template, confirmed by inspection), cannot both fit inside one MPS-split GPU's own
per-client memory share.

**This does not explain form (a), and that contradiction is not resolved here, stated plainly
rather than glossed over.** Form (a)/vLLM also put two vLLM processes on one `mps-2`-split GPU
(the same mechanism the paragraph above says should fail) and it succeeded, `RESTARTS=0`, on the
same day, same node family. On the numbers in this same page, MPS's own enforcement cannot be the
missing variable: if the daemon's per-client pinning were somehow not enforced at that moment, two
processes each requesting `28.87 GiB` still could not both start on one `31.38 GiB` device, which
form (a) did. Form (a) succeeding therefore means each of its two replicas requested roughly half
the device or less — not the `0.92` fraction (b)/(c) show. Whether that is because
`vllm/agg-baseline` and `vllm/disagg-pd` end up with a different *effective* memory utilization by
some path other than an explicit chart value (neither chart sets it explicitly, so if they differ
it is from vLLM's own code, not a value this platform sets) was not tested this round and is not
claimed — left as an open question for the next round, not resolved by this one. **No fix is
proposed or applied in this PR** until the discrepancy above is understood — the only claim this
round makes is the proximate traceback for (b)/(c), not a general "vLLM cannot share an MPS GPU"
claim the same page's own form (a) result would contradict.

**SGLang HiCache cold/warm retry.** Cold pass confirmed again in both round 2 and round 3
(`exit-code=0`). The warm pass remains unconfirmed in both rounds: round 2 produced an empty
`exit-code` (the Job-name-reuse bug this round meant to fix); round 3's own retry (waiting for the
old Job's Pod to actually disappear, not just the Job object, before reapplying) did not reach the
warm pass at all — the engine's own rollout timed out before the cold/warm comparison could run,
on a cluster shared with the other round-3 tests above; not re-investigated further within the
3-hour real-hardware time budget for this investigation.

**Known issues, final status for this investigation:**

| # | What | Status |
| --- | --- | --- |
| 1 | vLLM same-node MPS colocate (form (b)) | Proximate cause found (`--gpu-memory-utilization` vs. MPS share); contradicted by form (a)'s own success, not resolved; no fix proposed |
| 2 | vLLM 2-node MPS-disagg-over-EFA prefill crash loop (form (c)) | Same proximate cause and same open contradiction as #1 |
| 3 | SGLang HiCache warm pass | Not reached in round 3 (engine rollout timeout, not investigated further); still open |
| 4 | EFA byte-counter evidence for form (c) | Diagnostic command bug, not fixed this investigation |
| 5 | GPU-UUID evidence that MPS clients share one physical GPU in form (c) | Not captured this investigation |

## Conventions

- Node roles are told apart by a node label, `distai.dev/pd-role` by default, and every chart lets you change the key.
- A disaggregated layout is only compared with an aggregated baseline measured on the same hardware, with the same model revision, trace and SLO.
- Images are pinned by tag and digest. Services are `ClusterIP`; nothing is exposed outside the cluster by default.
- The disaggregated examples are GPU only: neither the vLLM Neuron plugin nor NeuronX Distributed Inference ships a disaggregated prefill/decode path today, and SGLang's disaggregation path has no Neuron variant.
- The vLLM and SGLang charts share their value names wherever the two engines share a concept (`placement.*`, `prefill.*`, `decode.*`, `engine.*`, `kvCacheTier.mode`, `metrics.enabled`); they differ where the engines do (`transport.*`), and the router in front of the roles is named per *chart*, not per engine, since the three router mechanisms genuinely differ: `proxy.*` in `vllm/disagg-pd` (the hand-written proxy), `routingSidecar.*`/`llmdRouter.*` in `vllm/disagg-pd-llmd` (llm-d's own Gateway-mode router), and `router.*` in `sglang/disagg-pd` (SGLang's own bundled router).
