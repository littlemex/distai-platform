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

## Conventions

- Node roles are told apart by a node label, `distai.dev/pd-role` by default, and every chart lets you change the key.
- A disaggregated layout is only compared with an aggregated baseline measured on the same hardware, with the same model revision, trace and SLO.
- Images are pinned by tag and digest. Services are `ClusterIP`; nothing is exposed outside the cluster by default.
- The disaggregated examples are GPU only: neither the vLLM Neuron plugin nor NeuronX Distributed Inference ships a disaggregated prefill/decode path today, and SGLang's disaggregation path has no Neuron variant.
- The vLLM and SGLang charts share their value names wherever the two engines share a concept (`placement.*`, `prefill.*`, `decode.*`, `engine.*`, `kvCacheTier.mode`, `metrics.enabled`); they differ where the engines do (`transport.*`), and the router in front of the roles is named per *chart*, not per engine, since the three router mechanisms genuinely differ: `proxy.*` in `vllm/disagg-pd` (the hand-written proxy), `routingSidecar.*`/`llmdRouter.*` in `vllm/disagg-pd-llmd` (llm-d's own Gateway-mode router), and `router.*` in `sglang/disagg-pd` (SGLang's own bundled router).
