# Shared measurement tools

The tools here measure any OpenAI-compatible vLLM endpoint the same way, so that a disaggregated run and its aggregated baseline are scored by identical rules. They wrap vLLM's own benchmark client rather than replacing it, and add only what no existing tool computes: a per-request longest inter-token gap, a joint SLO over planned requests, and goodput per GPU including drain.

| Directory | What it is |
| --- | --- |
| [`load-replay/`](load-replay/) | `run-load.sh` and the `load-job.yaml` Job that runs it in the cluster: open-loop Poisson load with `vllm bench serve`, send-lag rejection and pod snapshots |
| [`scorer/`](scorer/) | `score.py`, which scores saved per-request results against an SLO, and `to_prom.py`, which turns a score into Prometheus metrics |
| [`dashboards/`](dashboards/) | `vllm-pd.json` (Grafana 11) and `scrape-configs.yaml`, the scrape jobs it reads |

## Load replay

`run-load.sh` is a thin wrapper around vLLM's own benchmark client. It runs these steps, in this order, and keeps every artifact next to the `--output` file:

| Step | Output file | Why |
| --- | --- | --- |
| Snapshot the namespace's pods | `bench.pods-before.json` | A pod restart or replacement during the run shows up as a changed `restartCount` or UID |
| Run `vllm bench serve --request-rate R --num-prompts N --save-result --save-detailed`, inside a Python process whose garbage collector is frozen and disabled (`driver.py`) | `bench.json`, `bench.command.txt` | Open-loop: vLLM sends requests at Poisson arrival times, not when the previous one returns; a collector pause in the client would otherwise land in the results as a spurious gap |
| Snapshot the pods again | `bench.pods-after.json` | Compare with `bench.pods-before.json` |
| Take the largest of vLLM's own per-request `queue_times` and compare it with `--max-send-lag-ms` | exit code | A run whose client fell behind measured the client; it exits 3 with the measured lag and must not be scored |

The flags are `--target-url`, `--model`, `--num-prompts`, `--request-rate`, `--output`, `--max-send-lag-ms` and `--namespace`; anything after `--` goes to `vllm bench serve` unchanged, which is where the prompt shape is set (by default vLLM's `random` dataset). Run `run-load.sh --help` for the usage line.

Run it as a Job in the namespace of the target, so that requests go to the Service by in-cluster DNS and no client-to-cluster latency is mixed into TTFT. `load-job.yaml` is rendered with `envsubst` (part of GNU gettext). The values below are an example; `TARGET_URL` is the endpoint the chart's installation notes print.

```bash
export NAMESPACE=pd-demo
export RUN_ID=run1
export LAYOUT=disagg-pd
export TARGET_URL=http://pd-vllm-disagg-pd:8000
export MODEL_ID="${MODEL_ID:?set MODEL_ID to the model the target serves}"
export NUM_PROMPTS=600
export REQUEST_RATE=2
export MAX_SEND_LAG_MS=50
export BENCH_EXTRA_ARGS="--random-input-len 1024 --random-output-len 256 --seed 0"
kubectl create configmap load-replay-scripts -n "$NAMESPACE" \
  --from-file=examples/inference/_shared/load-replay/run-load.sh \
  --from-file=examples/inference/_shared/load-replay/driver.py
envsubst '${TARGET_URL} ${MODEL_ID} ${NUM_PROMPTS} ${REQUEST_RATE} ${MAX_SEND_LAG_MS} ${BENCH_EXTRA_ARGS}' \
  < examples/inference/_shared/load-replay/load-job.yaml \
  | kubectl apply -n "$NAMESPACE" -f -
```

The pod keeps its results until they are collected. Wait for the run to finish, copy the results out, then release the pod; the Job then ends as `Complete` when the run was valid and `Failed` otherwise.

```bash
kubectl wait -n "$NAMESPACE" --for=condition=Ready pod -l job-name=load-replay --timeout=30m
export POD="$(kubectl get pods -n "$NAMESPACE" -l job-name=load-replay -o jsonpath='{.items[0].metadata.name}')"
until kubectl exec -n "$NAMESPACE" "$POD" -- test -e /results/exit-code; do sleep 15; done
kubectl cp -n "$NAMESPACE" "$POD:/results" "results-$RUN_ID"
kubectl exec -n "$NAMESPACE" "$POD" -- touch /results/.collected
cat "results-$RUN_ID/exit-code"
```

Delete the Job with `kubectl delete job load-replay -n "$NAMESPACE"` before the next run.

`queue_times` is the time vLLM's client recorded between a request's dispatch from its arrival schedule and the moment it was sent. It catches a client that is too busy to start requests on time; it does not include a delay in waking up for a scheduled arrival, which vLLM does not record. Keep the request rate well within what one client process sustains, and treat the bound as a necessary check, not a proof that every arrival was on time.

### Controlling prefix reuse, to compare KV cache tiers (skeleton, not built or measured on real hardware yet)

`run-load.sh` needs no change for this: everything after `--` already goes to `vllm bench serve` unchanged, and that tool's own `--dataset-name prefix_repetition` dataset is the reuse-ratio knob (confirmed, `docs.vllm.ai/en/latest/cli/bench/serve.html`, fetched 2026-11-21) — `--prefix-repetition-num-prefixes K` splits `--num-prompts` requests across `K` shared prefixes (so `num-prompts / K` requests reuse each prefix) and `--prefix-repetition-prefix-len` sets the shared prefix's own token length. Comparing the three `kvCacheTier` tiers (`gpu-only`, `local`, `remote`) means holding this trace fixed and varying `kvCacheTier.mode` only, the same one-variable-at-a-time rule Decision 10 already applies to every other comparison in this directory.

**Warm cache, stated as an acceptance criterion, not left implicit — and two open gaps in how to do it, found in review, not yet closed**: a `remote` or `local` tier's own prefix hits only show up once something has actually written those blocks there, so scoring a cold cache against a warm one is not a tier comparison, it is a warm-up-time comparison wearing a tier-comparison's clothes. The obvious fix — run one untimed, unscored warm-up pass of the same trace before the scored pass — has two problems that are not yet solved:

1. **Same `--seed` for both passes replays more than the prefix.** `prefix_repetition` generates each request's own random suffix from the seed too, not only the shared prefix; a same-seed warm-up therefore caches the full prompt, not just the prefix, so the scored pass becomes a near-complete byte-for-byte replay regardless of `--prefix-repetition-num-prefixes`. Whether `vllm bench serve` has any built-in way to hold the shared prefixes fixed while varying each request's own suffix between the warm-up and scored passes is **not confirmed** — check this before trusting any tier comparison built this way.
2. **A warm GPU-resident cache answers for every tier, not just the one under test.** After warm-up, vLLM's own GPU-resident prefix cache is warm under `gpu-only`, `local` and `remote` alike, and vLLM consults it first regardless of `kvCacheTier.mode`. Unless the working set is deliberately sized to exceed GPU KV capacity, or the scored request is routed to an engine replica that did not itself run the warm-up, every mode reads from the same place and "the tiers made no difference" is a methodology artifact, not a finding. A valid comparison needs one of those two conditions, confirmed and stated for the specific run, not assumed.

Neither gap is closed here; both are named so a reader does not take a cold-vs-warm fix at face value.

**[KVTrace](https://github.com/aws-samples/amazon-elasticache-samples/tree/main/kvtrace)**, the tool named alongside Amazon ElastiCache's distributed KV caching announcement, is a candidate second check on the trace above, not a replacement for `score.py`: it records the KV-cache events vLLM (V1) or SGLang already emit over ZMQ, replays them offline against a hypothetical shared-cache capacity, and reports a hit rate — independent of this directory's own bookkeeping, so it can confirm (or contradict) that `--prefix-repetition-num-prefixes` actually produced the intended reuse ratio on the live engine, rather than trusting the load generator's own arithmetic. Not wired into `run-load.sh` or `score.py` here (its own license is listed as "TBD" in its README as of 2026-11-21, and recording its trace needs a real engine run, which this platform's own verification rules do not let a design task run) — a candidate step for follow-up issue B's own real-machine run: enable vLLM's/SGLang's KV-event publisher, run `kvtrace record` for the duration of a scored pass, then `kvtrace simulate`/`report` on the result as a second, independent number next to this directory's own `score.json`.

## Scoring

`score.py` needs only the Python standard library:

```bash
export GPU_COUNT=2
export TTFT_MS=2000
export GAP_MS=100
python3 examples/inference/_shared/scorer/score.py \
  --records "results-$RUN_ID/bench.json" \
  --planned-requests "$NUM_PROMPTS" \
  --gpu-count "$GPU_COUNT" \
  --ttft-ms "$TTFT_MS" --tpot-or-gap-ms "$GAP_MS" \
  --out "results-$RUN_ID/score.json"
```

It reads the one JSON object `vllm bench serve --save-detailed` writes, with per-request parallel arrays `ttfts`, `itls`, `errors`, `start_times`, `latencies` and `queue_times`. The rules:

| Rule | Detail |
| --- | --- |
| Success | `errors[i]` is the empty string |
| Longest gap | `max(itls[i])` in ms: the single worst stall a reader saw, which an average TPOT hides |
| Failed requests | Counted in `failed_requests`, excluded from the TTFT and longest-gap distributions, and never attaining |
| No inter-token gap | A successful request with an empty `itls[i]`. Counted in `no_tokens_generated`, excluded from both distributions, and never attaining: a limit on the gap cannot be shown to hold without a gap |
| Joint attainment | Successful requests with TTFT within `--ttft-ms` and longest gap within `--tpot-or-gap-ms`, divided by `--planned-requests`. The denominator is what the load generator was asked to send, not the number of records, so requests that were never sent or never answered count against the result. More records than planned requests is an error |
| Goodput per GPU | Jointly attaining requests / (`--gpu-count` x interval). The interval runs from the earliest arrival (`start_times[i] - queue_times[i]` over all requests) to the latest completion of a successful request (`start_times[i] + latencies[i]`), so drain is included. With no successful request it is 0 |
| Percentiles | p50/p90/p99 with linear interpolation between closest ranks (`numpy.percentile`'s default); `null` when the distribution is empty |
| Malformed input | Exit code 1 with a one-line message on stderr |

The summary has exactly these fields: `planned_requests`, `successful_requests`, `failed_requests`, `no_tokens_generated`, `joint_attainment_share`, `goodput_per_gpu`, `ttft_ms` and `longest_gap_ms`. Because it is computed from saved records, the same run can be re-scored against another SLO without re-running the load.

## Dashboard and the goodput panel

[`dashboards/vllm-pd.json`](dashboards/vllm-pd.json) shows engine latency histograms, queue depth, KV cache use, engine count and placement per role, NIXL KV transfer time and volume, EFA TX/RX and RDMA write bytes per node, GPU utilization and memory per node, and the joint-SLO goodput and attainment of scored runs. It reads four scrape jobs:

| Job | Source |
| --- | --- |
| `vllm` | [`dashboards/scrape-configs.yaml`](dashboards/scrape-configs.yaml); selects the engine pods of both charts by their `vllm-metrics=true` label |
| `efa-exporter` | the efa-node-exporter job of [awsome-distributed-ai eks-managed-observability](https://github.com/awslabs/awsome-distributed-ai/tree/main/observability/prometheus-grafana/eks-managed-observability) |
| `dcgm-gpu` | [`dashboards/scrape-configs.yaml`](dashboards/scrape-configs.yaml); selects NVIDIA's own [`dcgm-exporter`](https://nvidia.github.io/dcgm-exporter/helm-charts) DaemonSet |
| `distai-pd-score` | [`dashboards/scrape-configs.yaml`](dashboards/scrape-configs.yaml); a Prometheus Pushgateway holding the pushed scores |

Append the three jobs from `scrape-configs.yaml` to the collector's `scrape_configs` of that observability stack (it sends to Amazon Managed Service for Prometheus, per the RFC's own Decision 7, [#37](https://github.com/littlemex/distai-platform/issues/37)), and import `vllm-pd.json` in Grafana with that Prometheus data source.

Install `dcgm-exporter` itself with its own `serviceMonitor.enabled` turned off, since this pipeline has no Prometheus Operator CRDs for that chart's own default `ServiceMonitor` to attach to (this pipeline's own collector discovers targets through `scrape-configs.yaml`'s `kubernetes_sd_configs` above instead):

```bash
helm repo add dcgm-exporter https://nvidia.github.io/dcgm-exporter/helm-charts
helm upgrade --install dcgm-exporter dcgm-exporter/dcgm-exporter \
  --namespace monitoring --create-namespace \
  --set serviceMonitor.enabled=false
```

If the cluster already runs the NVIDIA GPU Operator for driver/toolkit management, it bundles `dcgm-exporter` itself (`dcgmExporter.enabled: true` by default) and a separate install above is redundant — check which path the cluster actually uses before installing a second copy. The `dcgm-gpu` job's own `relabel_configs` already matches either path's own Pod labels (the standalone chart's `app.kubernetes.io/name: dcgm-exporter`, or the GPU Operator's own bundled `app: nvidia-dcgm-exporter` — confirmed different from each project's own source, 2026-11-21), so no job change is needed when switching between them. The `GPU utilization percent, per node` and `GPU memory used bytes, per node` panels (`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`) are skeleton panels: no real run has fed the `dcgm-gpu` job yet, so their numbers are unverified until a follow-up issue's own real-machine run confirms them.

Grafana cannot read a one-shot JSON file, so each score is pushed to a Pushgateway, which keeps the last push per run for the collector to scrape. Install it once, cluster-internal only:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install pushgateway prometheus-community/prometheus-pushgateway \
  --version 3.11.2 --namespace monitoring --create-namespace \
  --set fullnameOverride=pushgateway
```

Push a score from inside the cluster. The layout, the run and the SLO it was scored against form the Pushgateway grouping key, so they become labels of every pushed metric.

```bash
python3 examples/inference/_shared/scorer/to_prom.py --summary "results-$RUN_ID/score.json" \
  | kubectl run "push-$RUN_ID" --rm -i --restart=Never -n monitoring \
    --image=curlimages/curl:8.23.0 -- \
    curl -sS --data-binary @- "http://pushgateway.monitoring.svc:9091/metrics/job/distai-pd-score/layout/$LAYOUT/run_id/$RUN_ID/slo_ttft_ms/$TTFT_MS/slo_gap_ms/$GAP_MS"
```

The Pushgateway has no authentication; any pod in the cluster can push to it. It is a `ClusterIP` Service and must stay one.
