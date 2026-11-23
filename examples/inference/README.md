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

## MPS (GPU sub-device sharing), rounds 2-4: label-design fix, the 3 forms, and the vLLM memory-utilization fix (real hardware, `us-east-1`, `g7.8xlarge`/`g7.48xlarge`, 2026-11-22)

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
health was NOT re-observed at that same moment — `kubectl get pods` showed `1/2 Ready`, `Error`,
2 restarts, 44s after creation (Pod-level status; which of the Pod's two containers reported
`Error` was not captured, so whether this is, or is not, the same "config-watcher sidecar restarts
after relabel, main container stays healthy" oddity `capacity-pool/README.md` documents elsewhere
is not established either way — no relabel happened here, which argues against it being that exact
oddity, but a Pod-level `1/2 Ready` is also consistent with one container, sidecar included,
failing). A real workload was served from this same node a few minutes later with `RESTARTS=0`
(form (a) below), which is evidence the daemon had become healthy by then, but that inference
stands in place of a direct re-read of the daemon Pod's own status at a later timestamp — not yet
done.

**The 3 forms, each tried on both engines.** All cells target this one drift-replaced node/pool pair unless noted.

| Form | Engine | Result |
| --- | --- | --- |
| (a) Aggregated, 1 GPU x 2 replicas | vLLM | Confirmed: both replicas on the same node (`ip-10-0-100-212`), `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=3.997`, TTFT p50/p90/p99 = 8.6/11.1/18.9 ms |
| (a) Aggregated, 1 GPU x 2 replicas | SGLang | Confirmed: both replicas on the same node (`ip-10-0-100-212`), `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=4.005`, TTFT p50/p90/p99 = 9.6/66.7/92.8 ms |
| (b) Same-node prefill+decode colocate | vLLM | **Blocked in rounds 2-3 by a real, reproducible defect (proximate cause found in round 3, not fully explained -- see below), not purely a scheduling issue; fixed and confirmed in round 4 -- see Known issue #1.** Two distinct attempts in rounds 2-3, two distinct outcomes: the first (missing `enforceAntiAffinity=false`, the chart's own "fault-injection shape" -- its own `placement.enforceAntiAffinity` default renders a required anti-affinity that keeps decode off prefill's node, documented in `vllm/disagg-pd/values.yaml`/`NOTES.txt`) never colocated at all -- `decode` stayed `Pending`, `node=<none>`, for its own 12-minute window. Decode's own required anti-affinity would normally let Karpenter launch a second node instead of leaving it `Pending`, but the `gpu-shared` pool's own `limits: {cpu: "32"}` caps it to exactly one `g7.8xlarge` node (`32` vCPU), so no second node was available within that pool for decode to land on -- exactly the "fault-injection shape" the chart's own values.yaml/NOTES.txt describes for a one-node pool. The corrected retry (`enforceAntiAffinity=false`) did colocate both roles onto one node (`ip-10-0-75-10`), and only then crashed: both containers reached `CrashLoopBackOff`, `successful_requests=0/40`, `failed_requests=40/40`. Round 4 re-ran this same shape with `prefill.mps.enabled`/`decode.mps.enabled: true` set and reached `Running`/`Ready`, `RESTARTS=0`, with a real completion -- see the "Proximate cause" section below for the full log |
| (b) Same-node prefill+decode colocate | SGLang | Confirmed (with `enforceAntiAffinity=false`): decode, prefill and the router all on the same node (`ip-10-0-100-212`), `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=4.001`, TTFT p50/p90/p99 = 18.2/22.8/146.2 ms |
| (c) 2-node disaggregated over EFA, MPS-shared prefill | vLLM | **Blocked by the same proximate cause as (b), not fully explained -- see below.** `decode` (separate `g7.8xlarge` node) reached `Running`/`Ready`; both `prefill` replicas (same `g7.48xlarge` MPS-shared node) crash-looped in both round 2 and round 3. **Round 4's own fix was not verified on this shape** (an unrelated image-pull timeout blocked the re-run, see Known issue #2) -- still open |
| (c) 2-node disaggregated over EFA, "MPS-shared" prefill (quoted — round 4 found the two prefill replicas did NOT actually share one physical GPU, see below) | SGLang | Functionally confirmed: `decode` (separate `g7.8xlarge` node) and both `prefill` replicas (same `g7.48xlarge` node) all `Running`/`Ready`, `RESTARTS=0`, `successful_requests=40/40`, `goodput_per_gpu=1.338`. At the time this row was written: (1) the EFA `hw_counters` diagnostic returned empty for every pod in round 2, not re-attempted; (2) no GPU UUID was captured, so whether the two "MPS" clients shared one physical GPU or landed on two of the node's 8 physical GPUs was undistinguished. **Round 4 closed (2): the two prefill replicas got two different physical GPU UUIDs** (`GPU-cb86dd16-3984-7a5b-d577-82f2d1f7a509`/`GPU-f50ed8a5-11ec-7261-ea34-f62d869cff02`) — this row is a same-node, 2-of-8-physical-GPUs measurement, not a true single-GPU MPS-sharing measurement; the node's own `mps-2` device-plugin config did not, in this run, place both replicas on one physical device. (1) (EFA byte counters) is still open |

**`goodput_per_gpu` is not established to be on a common basis across this table, found by Fable
5.2 review — do not compare rows against each other.** Forms (a) and (b)'s own `score.py` calls
passed `--gpu-count 1` (the one shared *physical* GPU — not in question for these two forms, since
both roles are confirmed on the same single node). Form (c) passed `--gpu-count 3` (counting
*requested* `nvidia.com/gpu` units: 2 "MPS-shared" prefill replicas + 1 decode). Round 4 (see the
SGLang row above and Known issue #5) found the two prefill replicas landed on two different
physical GPUs, so `3` does match this row's own physical GPU count — but that itself means
`goodput_per_gpu=1.338` for SGLang's own form (c) is not a measurement of true MPS sub-device
sharing at all (no sharing happened), so it still does not belong next to (a)/(b)'s own numbers,
which *are* confirmed single-physical-GPU measurements: form (c) used 3 separate physical GPUs,
(a)/(b) used 1. The `4.0`-ish numbers in (a)/(b) and the `1.338` in (c) are therefore
not confirmed comparable on any single convention, and this page's own stated rule (compare only
on the same trace, model and SLO) does not hold across forms either. Each row's own number is real
(the underlying `successful_requests`/`joint_attainment_share` values are not affected by this),
but no cross-form "(c) is N times worse per GPU" conclusion is supported — not re-scored this
round to stay inside the real-hardware time
budget.

### Proximate cause for vLLM forms (b) and (c), found in round 3; fixed and confirmed for form (b) in round 4, form (c) still open

Round 3 found forms (b) and (c)'s vLLM crashes sharing the same traceback
(`vllm/v1/worker/gpu_worker.py`'s `request_memory`):

```text
ValueError: Free memory on device cuda:0 (15.72/31.38 GiB) on startup is less than desired GPU
memory utilization (0.92, 28.87 GiB). Decrease GPU memory utilization or reduce GPU memory used
by other processes.
```

and could not explain why form (a) (also two vLLM processes on one `mps-2`-split GPU) succeeded
under what it assumed was the same mechanism — stated as an open contradiction, no fix proposed.

**Round 4 (real hardware, `us-east-1`, `g7.8xlarge`/`g7.48xlarge`, 2026-11-22) adds one new real
data point, and does NOT resolve the contradiction** — an earlier draft of this section claimed it
did; that claim did not survive review and is corrected here. Reading form (a)'s own engine log
directly (not done in round 3) shows:

```text
INFO [gpu_worker.py:1175] Free memory on device (15.72/31.38 GiB) on startup. Desired GPU memory
utilization is (1.0, 31.38 GiB). Actual usage is 1.21 GiB for consumed memory (weights + non-torch),
0.52 GiB for peak activation, and 0.25 GiB for CUDAGraph memory. Replace gpu_memory_utilization
config with `--kv-cache-memory=31403986944` (29.25 GiB) to fit into requested memory, or
`--kv-cache-memory=14597829744` (13.6 GiB) to fully utilize gpu memory. Current kv cache memory in
use is 29.64 GiB.
[kv_cache_utils.py:1168] GPU KV cache size: 1,110,016 tokens, Maximum concurrency for 32,768 tokens
per request: 33.88x
```

This is an `INFO` line, not an error — `vllm/agg-baseline` did not crash. But it is **not** evidence
of a graceful clamp to the MPS-limited free share either: `Current kv cache memory in use is
29.64 GiB` is close to the *desired*, whole-device-sized `29.25 GiB` the message itself offers as
"fit into requested memory" — far above the `15.72 GiB` the same line reports as free. Whatever
vLLM actually did here, it was not "shrink the allocation to fit inside 15.72 GiB and start" (that
would read closer to the message's own `13.6 GiB` "fully utilize gpu memory" alternative); the
engine still reports the KV cache as sized near the full desired fraction, and still did not raise.
Why that specific combination does not trigger the `ValueError` round 3 reproduced on `disagg-pd`
is **not established by this log**. The round-3 traceback itself reported a desired fraction of
`0.92`; this round's own `agg-baseline` log reports `1.0` — two different numbers, from two
different charts, and this round did not test whether that difference (rather than the
`NixlConnector`-vs-not difference, or a different vLLM/image behavior, or something else) is what
matters. **The "open contradiction" from round 3 stands, with one additional, only partly
understood, real log added to it — it is not resolved, and no claim that it is resolved should be
read into this page or any PR text citing it.**

**The fix applied in this PR (`engine.mps`/`*.mps` + `gpuMemoryUtilization`, see Changes) is
confirmed working on real hardware for the previously-crashing case — independent of whether the
paragraph above is ever fully explained.** `disagg-pd`'s same-node colocate (form (b)'s corrected
shape, `placement.sameNodeMeasurement=true`, `enforceAntiAffinity=false`, NIXL over UCX rather than
LIBFABRIC this round, to measure on a single EFA-less `g7.8xlarge`) with
`prefill.mps.enabled=true`/`decode.mps.enabled=true`, `mps.replicas: 2` (the chart's own computed
default, `0.70/2 = 0.35`) reached `Running`/`Ready` on both roles, `RESTARTS=0`, and served a real
completion through the proxy (`" Paris. It was founded in the 12th century, and it's"`). The same
cell's own unmodified `disagg-pd` (no `mps.*` set, vLLM's own default fraction, same node)
reproduced the original `CrashLoopBackOff` (confirmed again by `RESTARTS`/pod status, though this
round's own log capture missed the crashing container's exact traceback — `kubectl logs` without
`--previous` caught the live container between restarts, a gap in this round's own script, not
evidence of a different failure mode, but not a re-confirmation of the exact `ValueError` either).
**This A/B pair (same node, same cell, only `mps.*` changed) is the one claim this round makes with
confidence: setting an explicit, MPS-aware fraction turns a real crash loop into a real, working
server on real hardware, for one request.** This is "starts and answers," not a load test: the
chart's own `0.70/replicas` default (`0.35` here) was the only fraction tried this round — the
`0.90/replicas` ceiling's own boundary (`0.45`) was not itself tried, so whether a value right at
the ceiling also starts cleanly is not confirmed either. Nor does a successful single completion
rule out the engine running closer to its own real memory limit than `0.35`'s own 35%-of-device
figure suggests — actual physical memory committed under concurrent load (multiple requests, a
larger model, or both MPS clients active at once) was not measured this round, and round 4's own
form (a) finding (immediately below) is a reason for caution here, not reassurance: a vLLM process
can keep running past what this page's own numbers say should be free. Why `disagg-pd`'s own
un-fixed default takes a different path than
`agg-baseline`'s own un-fixed default is left exactly as open as round 3 left it — the leading
candidate, not confirmed in isolation and not elevated to fact anywhere in this PR's own template
comments, is that `NixlConnector`'s own memory registration (present in every `disagg-pd`/
`disagg-pd-llmd` role, absent from `agg-baseline`'s default `gpu-only` tier) changes which branch
vLLM's own memory sizing takes; a difference in the two charts' pinned image build or vLLM version
behavior was not ruled out either.

**SGLang HiCache cold/warm, the cold/warm pass itself completed for the first time in round 4,
after two rounds that each failed for an unrelated infra reason (a Job-name-reuse bug, then an
engine rollout timeout on a shared cluster) — the TTFT numbers are real, but do not confirm
HiCache's own hit behavior specifically, stated plainly rather than overclaimed.** Run in
isolation this round (dedicated namespace, no concurrent test, `g7.8xlarge` decode-pool node,
`kvCacheTier.mode=local`, `--hicache-size 4`): a cold request and a warm request with the
identical long, repeated-filler prefix both returned a real completion;
`TTFT_PROXY_TOTAL_TIME` (curl's own `time_starttransfer`) was `0.058s` cold and `0.038s` warm.
This drop is consistent with a cache hit, but SGLang's own always-on GPU radix cache (on
regardless of `kvCacheTier.mode`), an ordinary first-request warmup effect (CUDA graph capture,
connection setup), or plain trial-to-trial variance (`n=1` per condition, no repeats) could each
produce the identical shape without HiCache's own hierarchical tier doing anything — this single
cold/warm pair, with no HiCache-off control run in the same session and no repeated sampling, does
not distinguish between those explanations. What this round closes is narrower than "HiCache
improves TTFT": it closes "the cold/warm pass can run end to end without hitting the two
unrelated bugs the prior rounds hit."

**Known issues, status after round 4:**

| # | What | Status |
| --- | --- | --- |
| 1 | vLLM same-node MPS colocate (form (b)) | **Fixed and confirmed on real hardware** (`engine.mps`/`*.mps` + `gpuMemoryUtilization`, see Changes): the A/B pair above (same node, only `mps.*` changed) turns a real crash loop into a real, working server. **The "open contradiction" from round 3 is NOT resolved** — round 4 adds one more real log (form (a) logs an `INFO` line and does not clamp to the reported free share either, a new, only partly understood data point) but does not explain why `disagg-pd`'s own un-fixed default takes a different path than `agg-baseline`'s own un-fixed default; leading candidate (`NixlConnector`'s own memory registration), not confirmed in isolation |
| 2 | vLLM 2-node MPS-disagg-over-EFA prefill crash loop (form (c)) | Not re-verified with the fix this round: a fresh `g7.48xlarge` node's own image pull exceeded the Deployment's default `progressDeadlineSeconds` (600s) before the prefill pods left `ContainerCreating`, an unrelated infra timing issue, not re-attempted to stay inside the real-hardware time budget — still open, and this item's own crash loop is unaffected either way. **Prerequisite fix for re-verifying this item, not yet re-verified on real hardware:** every engine Deployment template (prefill/decode/aggregated, not the hand-written proxy or the SGLang router) now sets `progressDeadlineSeconds` to at least `max(600, engine.startupTimeoutSeconds + 300)` (2,100s by default) instead of the Kubernetes default alone, so `kubectl rollout status` no longer has to see the image pull finish inside 600s to let this item be re-attempted with that tooling (Kubernetes itself would have kept pulling and starting the pods past 600s either way; only `rollout status`'s own exit code was blocked — `helm install/upgrade --wait` is bounded by Helm's own separate `--timeout`, not by `progressDeadlineSeconds`, and needs that flag raised on its own if used here); whether the image pull plus the rest of a cold start now fits inside that larger window, and whether the crash loop itself still reproduces, is unverified |
| 3 | SGLang HiCache warm pass | The pass itself runs end to end now (round 4, see above); whether the observed TTFT drop is attributable to HiCache specifically, versus SGLang's own always-on radix cache or ordinary warmup, is not distinguished by this round's own single cold/warm pair — still open as a HiCache-specific measurement |
| 4 | EFA byte-counter evidence for form (c) specifically (MPS-shared prefill) | Still open for both engines: round 2's own attempt returned empty `hw_counters` for every pod (a diagnostic-command bug) and was not re-attempted this round. The "symmetric counters" confirmation cited elsewhere on this page (SGLang's own `tx_bytes`/`rdma_write_bytes` exactly matching decode's `rx_bytes`/`rdma_write_recv_bytes`) is from the separate 3-node prefill:decode ratio test over plain `LIBFABRIC` (no MPS involved), not from form (c) -- it does not close this item |
| 5 | GPU-UUID evidence for form (c) | **Closed for SGLang in round 4**: the two prefill replicas got two different physical GPU UUIDs (`GPU-cb86dd16...`/`GPU-f50ed8a5...`) — this topology's two MPS-shared "replicas" land on two of the node's 8 physical GPUs, not one shared GPU; still open for vLLM (blocked by #2) |

## Conventions

- Node roles are told apart by a node label, `distai.dev/pd-role` by default, and every chart lets you change the key.
- A disaggregated layout is only compared with an aggregated baseline measured on the same hardware, with the same model revision, trace and SLO.
- Images are pinned by tag and digest. Services are `ClusterIP`; nothing is exposed outside the cluster by default.
- The disaggregated examples are GPU only: neither the vLLM Neuron plugin nor NeuronX Distributed Inference ships a disaggregated prefill/decode path today, and SGLang's disaggregation path has no Neuron variant.
- The vLLM and SGLang charts share their value names wherever the two engines share a concept (`placement.*`, `prefill.*`, `decode.*`, `engine.*`, `kvCacheTier.mode`, `metrics.enabled`); they differ where the engines do (`transport.*`), and the router in front of the roles is named per *chart*, not per engine, since the three router mechanisms genuinely differ: `proxy.*` in `vllm/disagg-pd` (the hand-written proxy), `routingSidecar.*`/`llmdRouter.*` in `vllm/disagg-pd-llmd` (llm-d's own Gateway-mode router), and `router.*` in `sglang/disagg-pd` (SGLang's own bundled router).
