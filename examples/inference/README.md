# Inference Examples

Self-contained references for serving models on an EKS cluster. Each example is deployed with `helm` or `kubectl` directly and does not depend on this repository's GitOps delivery; the cluster only has to provide the GPU and EFA device plugins and node labels the example's README lists. Examples are grouped by serving engine, and each one has its own README with prerequisites, copy-paste instructions and known issues.

| Engine | Example | Description |
| --- | --- | --- |
| [`vllm`](vllm/) | [`disagg-pd`](vllm/disagg-pd/) | Prefill/decode disaggregated serving with vLLM's NixlConnector over libfabric/EFA, a prefill-then-decode proxy, a free prefill:decode ratio, and prefill and decode kept on different nodes by default |
| [`vllm`](vllm/) | [`agg-baseline`](vllm/agg-baseline/) | Aggregated vLLM serving with vLLM's default scheduler, the baseline the disaggregated layout is compared against on the same hardware |

Shared measurement tools used by every example:

| Tool | Description |
| --- | --- |
| [`_shared/load-replay`](_shared/load-replay/) | In-cluster, open-loop Poisson load with `vllm bench serve` as a Kubernetes Job, rejecting runs whose client fell behind and snapshotting pods before and after |
| [`_shared/scorer`](_shared/scorer/) | Scores saved per-request results against an explicit joint SLO: TTFT limit, longest inter-token gap limit, share of planned requests meeting both, and goodput per GPU including drain |
| [`_shared/dashboards`](_shared/dashboards/) | Grafana dashboard for vLLM prefill/decode serving, NIXL KV transfer, EFA counters and scored goodput, with the scrape jobs it reads |

How to measure with them is described in [`_shared/README.md`](_shared/README.md).

## Status

Only the vLLM examples above exist and have run on real hardware (see the RFC, [#37](https://github.com/littlemex/distai-platform/issues/37), follow-up issue B). SGLang's own disaggregated example (follow-up issue C) and llm-d's own router mode (follow-up issue A) are not built here and have not run on any hardware yet — time-boxed out of the first real-machine round, not found broken. Before either is measured on a Capacity Block window or any other paid hardware, run it first on a smaller, cheaper GPU instance to produce a real, if rough, timing, the same way the vLLM path's own dry run already did.

## Conventions

- Node roles are told apart by a node label, `distai.dev/pd-role` by default, and every chart lets you change the key.
- A disaggregated layout is only compared with an aggregated baseline measured on the same hardware, with the same model revision, trace and SLO.
- Images are pinned by tag and digest. Services are `ClusterIP`; nothing is exposed outside the cluster by default.
- The disaggregated examples are GPU only: neither the vLLM Neuron plugin nor NeuronX Distributed Inference ships a disaggregated prefill/decode path today.
