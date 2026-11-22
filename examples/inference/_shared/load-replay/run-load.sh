#!/usr/bin/env bash
# Open-loop load against an OpenAI-compatible endpoint (vLLM or SGLang), kept honest.
#
# 1. Snapshots the pods of the namespace (OUTPUT without .json, plus
#    .pods-before.json).
# 2. Runs `vllm bench serve` with Poisson arrivals at --request-rate for
#    --num-prompts requests, saving the per-request detail
#    (--save-result --save-detailed) at --output. vLLM runs inside this
#    script's Python driver (driver.py), which freezes and disables the
#    garbage collector before the benchmark starts.
# 3. Snapshots the pods again (.pods-after.json); a pod restart or
#    replacement during the run shows up as a changed restartCount or UID.
# 4. Reads vLLM's own per-request queue_times and exits 3 when the largest
#    exceeds --max-send-lag-ms: the client fell behind, so the run measured
#    the client, not the server, and is invalid.
#
# Meant to run inside the cluster (load-job.yaml), reaching the target by
# in-cluster DNS. Requires python3 with vLLM installed (the vLLM image).
# Arguments after "--" are passed to `vllm bench serve` unchanged, for
# example "-- --random-input-len 2048 --random-output-len 256 --seed 1".
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-load.sh --target-url URL --model ID --num-prompts N
                   --request-rate REQ_PER_S --output FILE.json
                   --max-send-lag-ms MS --namespace NS
                   [-- extra vllm bench serve arguments]
EOF
}

die() {
  echo "run-load.sh: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_url="" model="" num_prompts="" request_rate="" output=""
max_lag_ms="" namespace=""
extra=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      extra=("$@")
      break
      ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --target-url) target_url="$2" ;;
    --model) model="$2" ;;
    --num-prompts) num_prompts="$2" ;;
    --request-rate) request_rate="$2" ;;
    --output) output="$2" ;;
    --max-send-lag-ms) max_lag_ms="$2" ;;
    --namespace) namespace="$2" ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift 2
done

for name in target_url model num_prompts request_rate output max_lag_ms namespace; do
  [ -n "${!name}" ] || {
    usage >&2
    die "missing required argument: --${name//_/-}"
  }
done
case "$output" in
  *.json) ;;
  *) die "--output must end in .json" ;;
esac

out_dir="$(dirname "$output")"
out_name="$(basename "$output")"
stem="${output%.json}"
mkdir -p "$out_dir"

# Raw pod list of the namespace, unmodified: kubectl when present, otherwise
# the same object straight from the API server with the pod's own token
# (the vLLM image has no kubectl).
snapshot_pods() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl get pods -n "$namespace" -o json >"$1"
  else
    python3 -I - "$namespace" "$1" <<'EOF'
import ssl, sys, urllib.request
sa = "/var/run/secrets/kubernetes.io/serviceaccount"
ns, out = sys.argv[1], sys.argv[2]
with open(f"{sa}/token") as f:
    token = f.read().strip()
req = urllib.request.Request(
    f"https://kubernetes.default.svc/api/v1/namespaces/{ns}/pods",
    headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
)
ctx = ssl.create_default_context(cafile=f"{sa}/ca.crt")
with urllib.request.urlopen(req, context=ctx, timeout=30) as resp, open(out, "wb") as f:
    f.write(resp.read())
EOF
  fi
}

bench_args=(
  bench serve
  --backend vllm
  --base-url "$target_url"
  --endpoint /v1/completions
  --model "$model"
  --dataset-name random
  --num-prompts "$num_prompts"
  --request-rate "$request_rate"
  --percentile-metrics "ttft,tpot,itl,e2el"
  --metric-percentiles "50,90,99"
  --save-result --save-detailed
  --result-dir "$out_dir"
  --result-filename "$out_name"
  --disable-tqdm
  ${extra[@]+"${extra[@]}"}
)

printf '%q ' python3 "$here/driver.py" "${bench_args[@]}" >"$stem.command.txt"
echo >>"$stem.command.txt"

snapshot_pods "$stem.pods-before.json"
bench_rc=0
python3 "$here/driver.py" "${bench_args[@]}" || bench_rc=$?
snapshot_pods "$stem.pods-after.json"

[ "$bench_rc" -eq 0 ] || die "vllm bench serve exited with $bench_rc"

python3 -I - "$output" "$max_lag_ms" <<'EOF'
import json, sys
path, bound_ms = sys.argv[1], float(sys.argv[2])
try:
    with open(path) as f:
        queue_times = json.load(f)["queue_times"]
    worst_ms = max((abs(float(q)) for q in queue_times), default=0.0) * 1000.0
except (OSError, ValueError, KeyError, TypeError) as e:
    sys.exit(f"run-load.sh: cannot read queue_times from {path}: {e}")
if worst_ms > bound_ms:
    print(
        f"run-load.sh: run invalid: max send lag {worst_ms:.1f} ms exceeds "
        f"--max-send-lag-ms {bound_ms:g}",
        file=sys.stderr,
    )
    sys.exit(3)
print(f"run-load.sh: max send lag {worst_ms:.1f} ms (bound {bound_ms:g} ms)")
EOF
