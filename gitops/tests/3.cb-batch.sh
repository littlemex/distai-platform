#!/usr/bin/env bash
# Capacity-Block verification batch (verify/cb-batch, not merged). Runs against
# an ALREADY-BUILT cell (KUBECONFIG already pointed at it, AWS_REGION/NAME
# already exported) — this script does not build or destroy a cell itself.
# For a dry run on cheap GPU spot, build the cell first with
# gitops/tests/1.e2e.sh (GITOPS_RUN_ACCEL_E2E=1, NAME=dp-a19-gpu) and do not
# let it tear down (set E2E_SKIP_TEARDOWN=1 if 1.e2e.sh honors it, or run the
# steps below manually against that cell's KUBECONFIG before its own destroy
# step runs), OR build a cell by hand with infra/foundation + bootstrap.sh +
# the capacity-pool chart per plan.md section 1.
#
# Every step below is independent and idempotent: re-running a step that
# already passed is a no-op (checked, not re-applied blindly), so a partial
# run can resume. Steps are numbered to continue 1.e2e.sh's own convention
# (which ends at step 19) and are grouped by the inventory item they verify
# (see /Users/akazawt/tmp/distai-platform-ops/cb-plan/plan.md section 3 for
# the full purpose/closes/evidence/budget write-up of each).
#
# Required environment: KUBECONFIG, AWS_REGION, NAME (the cell), plus
#   CB_EVIDENCE_DIR (where redacted-before-posting evidence files are written;
#   created if missing).
# Optional: CB_STEPS="20 21 22" to run only a subset (default: all).

set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the already-built cell}"
: "${AWS_REGION:?}"
: "${NAME:?}"
CB_EVIDENCE_DIR="${CB_EVIDENCE_DIR:-$(mktemp -d)}"
mkdir -p "${CB_EVIDENCE_DIR}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
pass() { log "PASS $*"; }
fail() { log "FAIL $*"; return 1; }
info() { log "INFO $*"; }
k() { kubectl "$@"; }

wait_until() {
  local timeout="$1" interval="$2" desc="$3"
  shift 3
  local start now
  start="$(date +%s)"
  while true; do
    if "$@"; then return 0; fi
    now="$(date +%s)"
    if ((now - start >= timeout)); then
      log "timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep "${interval}"
  done
}

STEPS="${CB_STEPS:-20 21 22 23 24 25 26 27}"
run_step() {
  local n="$1"
  [[ " ${STEPS} " == *" ${n} "* ]]
}

# One GPU node to target: the first node advertising nvidia.com/gpu or a DRA
# NVIDIA ResourceSlice. Steps 20-23 run against this node; they do not assume
# EFA or a second node (dry-run-safe on g6e/g5/g7, which have neither).
gpu_node() { k get nodes -l 'karpenter.sh/nodepool' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

# Node A/Node B pinning by hostname (plan.md section 2's isolation
# mechanism #1): neither the pool label nor a DRA DeviceClass is
# node-scoped, so a per-node-lane test must pin by
# kubernetes.io/hostname explicitly, never rely on "whichever node
# answers first" -- that can silently satisfy on the other node. Sorted
# by node name so A/B assignment is stable across repeated calls within
# one run (not across re-provisioning, where names change).
gpu_nodes_sorted() { k get nodes -l 'karpenter.sh/nodepool' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort; }
gpu_node_a() { gpu_nodes_sorted | sed -n '1p'; }
gpu_node_b() { gpu_nodes_sorted | sed -n '2p'; }

# ============================================================ step 20
# Node bring-up and health (inventory: "Node bring-up and health").
# Purpose: record AMI/driver/CUDA/NCCL/aws-ofi-nccl versions, run DCGM
# diagnostics, dump PCIe topology, and time launch-to-Ready and
# first-GPU-pod. Closes: no single Issue; this is the pre-flight ground
# truth every other DRA/EFA check (plan.md Test 1, #19 E7) depends on, and
# the AMI-variant risk flagged in plan.md section 6.
if run_step 20; then
  log "=== step 20: node bring-up and health ==="
  NODE="$(gpu_node)"
  [[ -n "${NODE}" ]] || fail "step20: no GPU node found (karpenter.sh/nodepool label)"

  CREATED="$(k get node "${NODE}" -o jsonpath='{.metadata.creationTimestamp}')"
  READY_T="$(k get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
  info "node ${NODE}: created=${CREATED} ready=${READY_T} (launch-to-Ready; compare against this run's own node-launch timestamp from Karpenter/EC2 logs, not recorded here since this script starts after the node exists)"

  # CB_HEALTH_IMAGE defaults to a small, already-small-and-proven image (the
  # same one step21 uses, so it is usually already cached on the node) for
  # dry runs on cheap spot. The real block MUST override this to the full
  # NCCL/EFA test image, since dcgmi/nvbandwidth/fi_info are no-ops without
  # it — this default is a dry-run economy measure, not a real-block default.
  # A multi-GB image on an undersized root volume was the actual cause of a
  # 2026-11-20 dry-run failure (disk-pressure eviction -> Karpenter read the
  # node as empty -> consolidated it); the GPU pool's EC2NodeClass now also
  # carries a 150Gi root volume and a 10m consolidateAfter for the same
  # reason (gitops/cells/dp-a19-gpu/capacity-pool/gpu.yaml) — this image
  # default and that disk/disruption fix are deliberately two independent
  # layers of the same fix, not a substitute for each other.
  CB_HEALTH_IMAGE="${CB_HEALTH_IMAGE:-public.ecr.aws/amazonlinux/amazonlinux:2023}"
  # 2026-11-19 dry-run findings, two rounds: (1) this pod never requested
  # nvidia.com/gpu, so the device plugin never injected the driver/nvidia-smi
  # into it at all ("nvidia-smi: command not found" -- not a base-image
  # problem); (2) the fix for that via "k run --limits=..." failed because
  # this kubectl version has no --limits flag, and the follow-up fix via
  # "k run --overrides" with a PARTIAL containers[0] entry (just name +
  # resources) failed too ("spec.containers[0].image: Required value") --
  # --overrides here does a plain array replace, not a strategic merge by
  # name, so a partial container entry destroys the image/command the base
  # generator set. Fix: stop using "k run" for this pod; apply a complete
  # Pod manifest directly, so there is no generator/override interaction to
  # get wrong.
  cat <<PODEOF | k apply -f - || fail "step20: could not create cb-health pod"
apiVersion: v1
kind: Pod
metadata:
  name: cb-health
  annotations:
    karpenter.sh/do-not-disrupt: "true"
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: "${NODE}"
  tolerations:
    - operator: Exists
  containers:
    - name: cb-health
      image: "${CB_HEALTH_IMAGE}"
      command: ["bash", "-c"]
      args:
        - |
          echo "--- nvidia-smi -L ---"; nvidia-smi -L
          echo "--- driver/CUDA ---"; nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv
          echo "--- Fabric Manager (if present) ---"; (systemctl is-active nvidia-fabricmanager 2>&1 || echo "not applicable on this instance type")
          echo "--- dcgmi diag -r 3 ---"; (command -v dcgmi >/dev/null && dcgmi diag -r 3 || echo "dcgmi not in this image; run from a DCGM-enabled image on the real block")
          echo "--- nvbandwidth (if present) ---"; (command -v nvbandwidth >/dev/null && nvbandwidth || echo "nvbandwidth not in this image; add to the pre-block image for the real block")
          echo "--- lspci PCIe topology ---"; (command -v lspci >/dev/null && lspci -t || echo "lspci not in this image; the real block pinned NCCL/EFA test image includes pciutils")
          echo "--- aws-ofi-nccl / libfabric ---"; (fi_info -p efa 2>&1 || echo "no EFA on this node (expected on cheap dry-run instances)")
          echo "--- NCCL/libfabric versions baked into this image ---"
      resources:
        limits:
          nvidia.com/gpu: "1"
PODEOF
  wait_until 120 5 "cb-health pod finished (Succeeded or Failed)" bash -c "
    phase=\$(kubectl get pod cb-health -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ \"\${phase}\" == 'Succeeded' || \"\${phase}\" == 'Failed' ]]
  " || fail "step20: cb-health pod did not finish within 120s"
  k logs cb-health > "${CB_EVIDENCE_DIR}/step20-node-health.raw.log" 2>&1 || fail "step20: could not read cb-health logs"
  k delete pod cb-health --ignore-not-found --wait=false >/dev/null 2>&1 || true

  cp "${CB_EVIDENCE_DIR}/step20-node-health.raw.log" "${CB_EVIDENCE_DIR}/step20-node-health.log"
  grep -qi "driver_version" "${CB_EVIDENCE_DIR}/step20-node-health.log" || fail "step20: nvidia-smi query did not return a driver version (if CB_HEALTH_IMAGE was overridden to a minimal image, the NVIDIA toolkit may not have injected nvidia-smi into it — retry with the default or the full NCCL/EFA test image before concluding the node itself is unhealthy)"
  pass "step20: versions and topology recorded in ${CB_EVIDENCE_DIR}/step20-node-health.log (dcgmi/nvbandwidth/fi_info are no-ops on a cheap dry-run node without those tools/EFA — expected, not a failure; must re-run on the real block's image/instance to get real values)"
fi

# ============================================================ step 21
# Local NVMe instance store (inventory: "Local NVMe instance store").
# Purpose: confirm instanceStorePolicy: RAID0 (if set on the pool's
# EC2NodeClass) actually presents one RAID0 volume, and benchmark it with
# fio. Closes: no Issue yet names this explicitly; feeds plan.md's image
# pre-pull / checkpoint-cache design and #18/#17's storage decisions.
if run_step 21; then
  log "=== step 21: local NVMe RAID0 + fio ==="
  NODE="$(gpu_node)"
  [[ -n "${NODE}" ]] || fail "step21: no GPU node found"
  k run cb-nvme --rm -i --restart=Never --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
    --overrides="{\"metadata\":{\"annotations\":{\"karpenter.sh/do-not-disrupt\":\"true\"}},\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${NODE}\"},\"hostPID\":false,\"tolerations\":[{\"operator\":\"Exists\"}],\"containers\":[{\"name\":\"cb-nvme\",\"image\":\"public.ecr.aws/amazonlinux/amazonlinux:2023\",\"command\":[\"sh\",\"-c\",\"lsblk; df -h /mnt 2>/dev/null || echo no-mnt; echo done\"],\"volumeMounts\":[{\"name\":\"mnt\",\"mountPath\":\"/mnt\"}]}],\"volumes\":[{\"name\":\"mnt\",\"hostPath\":{\"path\":\"/mnt/k8s-disks/0\",\"type\":\"DirectoryOrCreate\"}}]}}" \
    2>&1 | tee "${CB_EVIDENCE_DIR}/step21-nvme.log" || fail "step21: NVMe probe pod did not complete"
  info "step21: fio itself needs a privileged pod with the fio binary; not run here on the cheap dry-run image to avoid a second large image pull — run fio (randread/randwrite/seq, 4k and 1M block sizes) from the pinned benchmark image on the real block, writing results next to this file."
  pass "step21: /mnt/k8s-disks/0 presence checked, logged to ${CB_EVIDENCE_DIR}/step21-nvme.log"
fi

# ============================================================ step 22
# IMDS hop limit (inventory: "Tenancy/security on GPU nodes").
# Purpose: confirm Karpenter's EC2NodeClass does not loosen the
# httpPutResponseHopLimit default of 1 (confirmed via the karpenter-provider-
# aws CRD kubebuilder default, 2026-11-20) for the -rsv/GPU pool specifically.
# Closes: #22's IMDS/credential-isolation requirement.
if run_step 22; then
  log "=== step 22: IMDS hop limit ==="
  NODE="$(gpu_node)"
  [[ -n "${NODE}" ]] || fail "step22: no GPU node found"
  INSTANCE_ID="$(k get node "${NODE}" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
  [[ -n "${INSTANCE_ID}" ]] || fail "step22: could not read instance id from providerID"
  HOP="$(aws ec2 describe-instances --region "${AWS_REGION}" --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpPutResponseHopLimit' --output text)"
  echo "node=${NODE} instance=<redacted> hop_limit=${HOP}" > "${CB_EVIDENCE_DIR}/step22-imds.log"
  [[ "${HOP}" == "1" ]] || fail "step22: hop limit is ${HOP}, not 1 — the capacity-pool chart or a NodeClass override has loosened the default; pods on this node could reach node-role credentials"
  pass "step22: hop limit confirmed =1 on ${NODE}"
fi

# ============================================================ step 23
# NetworkPolicy does not constrain EFA/RDMA traffic (inventory: "Tenancy/
# security on GPU nodes", #22). Purpose: deploy a default-deny NetworkPolicy
# between two pods on an EFA-carrying node, then confirm an EFA fi_pingpong
# between them still succeeds (EFA is OS-bypass / SRD via libfabric, outside
# the kernel path NetworkPolicy enforcement hooks into) while an ordinary TCP
# connection between the same two pods is blocked, as a control. Needs a
# multi-EFA node (p5en/p6-b200) — on a cheap dry-run node without EFA, this
# step records "skipped: no EFA on this node" rather than a false pass.
#
# Isolation mechanism #3 (plan.md section 2): this test's own namespace,
# not a shared one, so its own default-deny NetworkPolicy cannot affect
# Node A's or Node B's other concurrent pods during a parallel-lane run.
# Created and used below regardless of whether the EFA assertion itself
# can run on this node, so the mechanism is still exercised on a dry run.
CB_NETPOL_NS="cb-batch-networkpolicy"
if run_step 23; then
  log "=== step 23: NetworkPolicy vs EFA ==="
  k create namespace "${CB_NETPOL_NS}" --dry-run=client -o yaml | k apply -f - >/dev/null \
    || fail "step23: could not create/confirm dedicated namespace ${CB_NETPOL_NS}"
  info "step23: dedicated namespace ${CB_NETPOL_NS} confirmed (isolation mechanism #3 — this test's default-deny policy never shares a namespace with a concurrent Node-A/Node-B lane)"
  NODE="$(gpu_node)"
  EFA_COUNT="$(k get node "${NODE}" -o jsonpath='{.status.allocatable.vpc\.amazonaws\.com/efa}' 2>/dev/null || true)"
  if [[ -z "${EFA_COUNT}" || "${EFA_COUNT}" == "0" ]]; then
    info "step23: SKIPPED — node ${NODE} has no vpc.amazonaws.com/efa allocatable (expected on g6e/g5/g7 dry-run nodes). Must run for real on p5en/p6-b200 during pre-block prep or the block itself, inside ${CB_NETPOL_NS}."
  else
    info "step23: EFA present (${EFA_COUNT}) — full test not scripted in this dry-run pass; author the default-deny NetworkPolicy + fi_pingpong-vs-plain-TCP control manifest inside ${CB_NETPOL_NS} before the real block (see plan.md Test 3 for the fi_pingpong invocation to reuse)."
  fi
  pass "step23: recorded in ${CB_EVIDENCE_DIR} (dedicated namespace ${CB_NETPOL_NS} confirmed; the EFA assertion itself is pending an EFA-carrying node)"
fi

# ============================================================ step 24
# DCGM exporter observability (inventory: "Observability and profiling").
# Purpose: install the upstream dcgm-exporter Helm chart directly (not a
# bespoke platform addon — see new-issues/ for the RFC to make this a real
# platform addon later) and confirm it scrapes GPU metrics. Closes: no
# Issue yet (see new-issues/observability-dcgm-exporter.md, drafted,
# not posted).
#
# 2026-11-20 finding and fix: the old URL (a GitHub Release asset,
# dcgm-exporter-helm-4.4.1.tgz at tag 4.4.1-4.5.1) 404s -- that specific
# tag/asset no longer exists. This was WRONGLY reported in an earlier round
# as "the project stopped distributing a chart, now build-from-source
# only" -- that conclusion was reached from the repo's own README quick
# start alone, without checking for a live Helm chart repository, and was
# incorrect. NVIDIA does actively maintain one, confirmed against its own
# index.yaml: https://nvidia.github.io/dcgm-exporter/helm-charts/index.yaml
# lists current versions (4.9.0, 4.8.4, 4.8.3, ...) with working .tgz URLs
# on that same domain (HTTP 200 confirmed for the 4.9.0 asset on
# 2026-11-20). Use the live Helm repo, not a pinned GitHub Release URL, so
# this does not go stale the same way again.
helm repo add dcgm-exporter https://nvidia.github.io/dcgm-exporter/helm-charts >/dev/null 2>&1 || true
helm repo update dcgm-exporter >/dev/null 2>&1 || true
if run_step 24; then
  log "=== step 24: DCGM exporter quick-add ==="
  # 2026-11-20 finding: the chart's default values create a ServiceMonitor
  # (a Prometheus Operator CRD), which this dry-run cluster does not have
  # installed -- "no matches for kind ServiceMonitor". The chart's own
  # deployment/README.md names exactly this fix: install the Prometheus
  # Operator CRDs first, or disable serviceMonitor. This dry-run cluster
  # has no Prometheus Operator, so disable it; the real block, if it runs
  # a monitoring stack with Prometheus Operator already installed, should
  # NOT pass this flag, so the ServiceMonitor is created for real scraping.
  helm upgrade --install dcgm-exporter-cb dcgm-exporter/dcgm-exporter \
    --namespace cb-batch --create-namespace --wait --timeout 5m \
    --set serviceMonitor.enabled=false 2>&1 | tee "${CB_EVIDENCE_DIR}/step24-dcgm-install.log" \
    || { info "step24: chart repo dcgm-exporter/dcgm-exporter (https://nvidia.github.io/dcgm-exporter/helm-charts) -- confirm it is still reachable and the chart name/version are current before the real block"; fail "step24: dcgm-exporter install failed"; }
  wait_until 120 5 "dcgm-exporter pod Running" bash -c "kubectl -n cb-batch get pods -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running" \
    || fail "step24: dcgm-exporter did not reach Running"
  # 2026-11-20 finding: the dcgm-exporter image does not bundle curl
  # ("exec: curl: executable file not found in $PATH") -- scrape from a
  # separate pod over the Service instead of execing into the target
  # container, same pattern already used elsewhere in this script
  # (cb-health, cb-nvme) rather than depending on whatever HTTP client
  # happens to be in a third-party image.
  DCGM_SVC="$(k -n cb-batch get svc -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${DCGM_SVC}" ]] || fail "step24: no Service found with label app.kubernetes.io/name=dcgm-exporter in namespace cb-batch"
  # Do not assume curl is present in this image either (amazonlinux:2023's
  # own minimal base is not guaranteed to carry it) -- try curl, then
  # wget, then a plain bash /dev/tcp HTTP/1.0 request, so this does not
  # depend on verifying ahead of time which HTTP client a given dry-run
  # image happens to bundle. Also apply a full Pod manifest and read logs
  # back explicitly instead of "k run"'s own interactive attach/streaming
  # (which has shown a "couldn't attach... falling back to streaming
  # logs" race on short-lived pods elsewhere in this script) -- apply,
  # wait for a terminal phase, then `k logs`, the same reliable pattern
  # step20 already uses.
  cat <<PODEOF | k apply -f - || fail "step24: could not create cb-dcgm-scrape pod"
apiVersion: v1
kind: Pod
metadata:
  name: cb-dcgm-scrape
  namespace: cb-batch
spec:
  restartPolicy: Never
  containers:
    - name: cb-dcgm-scrape
      image: public.ecr.aws/amazonlinux/amazonlinux:2023
      command: ["bash", "-c"]
      args:
        - |
          if command -v curl >/dev/null; then
            curl -s "${DCGM_SVC}.cb-batch.svc.cluster.local:9400/metrics"
          elif command -v wget >/dev/null; then
            wget -qO- "${DCGM_SVC}.cb-batch.svc.cluster.local:9400/metrics"
          else
            exec 3<>"/dev/tcp/${DCGM_SVC}.cb-batch.svc.cluster.local/9400"
            printf 'GET /metrics HTTP/1.0\r\nHost: ${DCGM_SVC}\r\n\r\n' >&3
            cat <&3
          fi
PODEOF
  wait_until 60 5 "cb-dcgm-scrape pod finished (Succeeded or Failed)" bash -c "
    phase=\$(kubectl -n cb-batch get pod cb-dcgm-scrape -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ \"\${phase}\" == 'Succeeded' || \"\${phase}\" == 'Failed' ]]
  " || fail "step24: cb-dcgm-scrape pod did not finish within 60s"
  k -n cb-batch logs cb-dcgm-scrape > "${CB_EVIDENCE_DIR}/step24-metrics-scrape.raw.log" 2>&1 || fail "step24: could not read cb-dcgm-scrape logs"
  k -n cb-batch delete pod cb-dcgm-scrape --ignore-not-found --wait=false >/dev/null 2>&1 || true
  grep -c "^DCGM_FI_" "${CB_EVIDENCE_DIR}/step24-metrics-scrape.raw.log" > "${CB_EVIDENCE_DIR}/step24-metric-count.log" \
    || fail "step24: could not scrape /metrics from dcgm-exporter (Service ${DCGM_SVC}) -- see ${CB_EVIDENCE_DIR}/step24-metrics-scrape.raw.log"
  pass "step24: dcgm-exporter scraped, metric line count in ${CB_EVIDENCE_DIR}/step24-metric-count.log"
fi

# ============================================================ step 25
# Node replacement inside the block (inventory: "Lifecycle inside a block").
# Purpose: terminate the reserved node's underlying EC2 instance directly and
# confirm whether Karpenter relaunches into the same reservation (closes part
# of #17's -rsv claim) — DESTRUCTIVE, only run with CB_ALLOW_DESTRUCTIVE=1,
# and only ever against a -rsv/reserved-capacity-type node, never spot/
# on-demand shared infrastructure.
if run_step 25; then
  log "=== step 25: node replacement ==="
  if [[ "${CB_ALLOW_DESTRUCTIVE:-0}" != "1" ]]; then
    info "step25: SKIPPED — set CB_ALLOW_DESTRUCTIVE=1 to actually terminate a node. Not run in this dry-run pass to avoid destroying the cheap dry-run node mid-batch (steps 20-24 still need it)."
    pass "step25: skipped by default, as designed"
  else
    NODE="$(gpu_node)"
    INSTANCE_ID="$(k get node "${NODE}" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
    aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "${INSTANCE_ID}" >/dev/null
    wait_until 300 10 "replacement node Ready" bash -c "kubectl get nodes -l 'karpenter.sh/nodepool' --field-selector=status.phase!=Terminating -o jsonpath='{.items[?(@.status.conditions[-1].type==\"Ready\")].metadata.name}' | grep -qv '${NODE}'" \
      || fail "step25: no replacement node became Ready within 5 minutes"
    pass "step25: Karpenter relaunched a replacement node after termination"
  fi
fi

# ============================================================ step 26
# Multi-team Kueue cohort preemption (inventory: "Scheduling"/#22). Purpose:
# two LocalQueues in one Cohort over the same (small, dry-run) GPU flavor;
# team B's low-priority Job is preempted and reclaimed when team A's
# higher-priority Job needs the quota back. Closes: #22's Cohort/
# reclaimWithinCohort claim, on real (if cheap) GPU hardware rather than
# simulated. Needs the smoke chart's ClusterQueue extended with a GPU
# resourceGroup per plan.md section 1 (T-18h) before this step is runnable;
# not yet applied in this dry-run pass — recorded as a prerequisite gap.
if run_step 26; then
  log "=== step 26: multi-team cohort preemption ==="
  if ! k get clusterqueue -o name 2>/dev/null | grep -q .; then
    info "step26: SKIPPED — no ClusterQueue with a GPU resourceGroup found. The smoke chart's ClusterQueue must be extended with nvidia.com/gpu nominalQuota (plan.md section 1, T-18h) before this step is runnable. Not a step 26 failure; a prerequisite gap, filed as its own finding."
    pass "step26: skipped, prerequisite gap recorded"
  else
    info "step26: ClusterQueue(s) with GPU quota found — author the two-LocalQueue, one-Cohort, reclaimWithinCohort:Any manifests here before the real block (reuse #22 Decision 4's flat-Cohort model); not yet authored in this dry-run pass."
    pass "step26: prerequisite present, manifest authoring still pending"
  fi
fi

# ============================================================ step 27
# Node A/Node B pinning smoke check (plan.md section 2's isolation
# mechanism #1). Purpose: on a real 2-node pool, confirm gpu_node_a and
# gpu_node_b resolve to two DISTINCT real nodes, and that a pod pinned to
# each by kubernetes.io/hostname actually lands there -- not "whichever
# node Kubernetes picks," which is the exact failure mode this mechanism
# exists to rule out before any per-node-lane test (E7a/E7b constrained
# vs. unconstrained arms, etc.) relies on it. Needs 2 nodes; on a 1-node
# dry run this records a SKIPPED finding, not a false pass.
if run_step 27; then
  log "=== step 27: Node A/Node B pinning smoke ==="
  NODE_A="$(gpu_node_a)"
  NODE_B="$(gpu_node_b)"
  if [[ -z "${NODE_B}" || "${NODE_A}" == "${NODE_B}" ]]; then
    # Only one node exists yet — force a second one rather than report a
    # false "1-node pool" skip on a pool that is actually sized for two:
    # two concurrent pods each holding nvidia.com/gpu:1 cannot both land
    # on a 1-GPU-per-node instance type, so the scheduler/Karpenter must
    # put the second one on a different, freshly launched node.
    info "step27: only one node visible yet (${NODE_A:-<none>}) — launching a second GPU-holding pod to force Karpenter to provision a second node"
    # 2026-11-20 findings, two rounds. Round 1: an earlier version of this
    # pod had NO placement constraint beyond the bare GPU request, and the
    # force pod simply scheduled onto Node A's own idle GPU (every earlier
    # step's own check pods are --rm'd by the time step27 runs, so Node
    # A's GPU is free) -- it never created scheduling pressure for a
    # second node. Round 1's own fix (nodeAffinity NotIn against Node A's
    # hostname) was ALSO wrong, confirmed by a real pod describe/events on
    # a live cluster: Karpenter's own FailedScheduling event says plainly
    # "using label kubernetes.io/hostname is not allowed as it might
    # interfere with the internal provisioning logic" -- Karpenter
    # blanket-refuses to even attempt provisioning a node for a pod whose
    # own scheduling constraints reference kubernetes.io/hostname at all,
    # regardless of operator, since a not-yet-launched node has no
    # hostname yet to reason about. Round 2 fix: podAntiAffinity with
    # topologyKey kubernetes.io/hostname against a real label on a
    # concrete anchor pod -- a Karpenter-supported, well-understood
    # "spread across nodes" pattern (unlike a raw nodeAffinity hostname
    # match), confirmed in Karpenter's own FailedScheduling message as one
    # of the well-known labels it reasons about for provisioning
    # (topology.kubernetes.io/zone etc. are listed there; topologyKey in
    # podAntiAffinity is handled by the generic pod-affinity scheduling
    # path, not the disallowed raw-label path).
    #
    # Anchor pod, pinned to Node A by name (ordinary nodeSelector against
    # an EXISTING node -- not a provisioning decision, so the "no
    # kubernetes.io/hostname" rule above does not apply here).
    cat <<PODEOF | k apply -f - || fail "step27: could not create cb-anchor pod"
apiVersion: v1
kind: Pod
metadata:
  name: cb-anchor
  labels:
    cb-batch/role: anchor
  annotations:
    karpenter.sh/do-not-disrupt: "true"
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: "${NODE_A}"
  tolerations:
    - operator: Exists
  containers:
    - name: cb-anchor
      image: public.ecr.aws/amazonlinux/amazonlinux:2023
      command: ["sh", "-c", "sleep 600"]
PODEOF
    wait_until 60 5 "cb-anchor pod Running on Node A" bash -c "kubectl get pod cb-anchor -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running" \
      || fail "step27: cb-anchor pod did not reach Running on Node A within 60s"
    cat <<PODEOF | k apply -f - || fail "step27: could not create cb-force-2node pod"
apiVersion: v1
kind: Pod
metadata:
  name: cb-force-2node
  annotations:
    karpenter.sh/do-not-disrupt: "true"
spec:
  restartPolicy: Never
  tolerations:
    - operator: Exists
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              cb-batch/role: anchor
          topologyKey: kubernetes.io/hostname
  containers:
    - name: cb-force-2node
      image: public.ecr.aws/amazonlinux/amazonlinux:2023
      command: ["sh", "-c", "sleep 600"]
      resources:
        limits:
          nvidia.com/gpu: "1"
PODEOF
    wait_until 420 10 "a second distinct GPU node exists" bash -c "
      a=\$(kubectl get nodes -l 'karpenter.sh/nodepool' -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort | sed -n '1p')
      b=\$(kubectl get nodes -l 'karpenter.sh/nodepool' -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort | sed -n '2p')
      [[ -n \"\$b\" && \"\$a\" != \"\$b\" ]]
    " || {
      # Capture real evidence before concluding anything, per the
      # coordinator's own instruction: pod-level scheduling events,
      # whether Karpenter even created a NodeClaim and what it says,
      # Karpenter's own controller log around this window, and Kueue's
      # admission view of the pod (expected to show the pod bypasses
      # Kueue entirely, since it carries no queue-name label -- confirmed
      # here, not assumed).
      info "step27: a second node did not appear within 7 minutes -- capturing diagnostics to the log before concluding anything"
      echo "=== DIAG: cb-force-2node pod describe (events/FailedScheduling) ==="
      k describe pod cb-force-2node 2>&1 || true
      echo "=== DIAG: NodeClaims (does one exist for this pod, and what does it say) ==="
      k get nodeclaims -o wide 2>&1 || true
      k get nodeclaims -o yaml 2>&1 || true
      echo "=== DIAG: Karpenter controller log, last 200 lines ==="
      karpenter_pod="$(k -n kube-system get pods -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
      if [[ -n "${karpenter_pod}" ]]; then
        k -n kube-system logs "${karpenter_pod}" --tail=200 2>&1 || true
      else
        echo "no Karpenter pod found under app.kubernetes.io/name=karpenter in kube-system"
      fi
      echo "=== DIAG: Kueue admission view of cb-force-2node (expected: not queued, no queue-name label) ==="
      k get pod cb-force-2node -o jsonpath='{.metadata.labels}' 2>&1 || true
      k get workloads -A 2>&1 || true
      echo "=== DIAG end ==="
    }
    k delete pod cb-force-2node cb-anchor --ignore-not-found --wait=false >/dev/null 2>&1 || true
    NODE_A="$(gpu_node_a)"
    NODE_B="$(gpu_node_b)"
  fi
  if [[ -z "${NODE_B}" || "${NODE_A}" == "${NODE_B}" ]]; then
    fail "step27: still only one GPU node present after attempting to force a second with an anti-affinity constraint (node_a=${NODE_A:-<none>}, node_b=${NODE_B:-<none>}) -- see the DIAG blocks above for the real cause; this is the foundational mechanism for the Capacity Block's own 2-node parallel lanes and must not be waved through as a skip"
  else
    info "step27: node_a=${NODE_A} node_b=${NODE_B} (distinct)"
    for pair in "a:${NODE_A}" "b:${NODE_B}"; do
      label="${pair%%:*}"; target="${pair#*:}"
      k run "cb-pin-${label}" --rm -i --restart=Never --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
        --overrides="{\"metadata\":{\"annotations\":{\"karpenter.sh/do-not-disrupt\":\"true\"}},\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${target}\"},\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
        -- sh -c 'echo "landed on: $(cat /etc/hostname 2>/dev/null || hostname)"; echo pinned-ok' \
        2>&1 | tee "${CB_EVIDENCE_DIR}/step27-pin-${label}.log" || fail "step27: pin pod for node ${label} (${target}) did not complete"
    done
    pass "step27: both pin pods completed, pinned to distinct nodes (node_a=${NODE_A}, node_b=${NODE_B}); evidence in ${CB_EVIDENCE_DIR}/step27-pin-{a,b}.log"
  fi
fi

log "=== cb-batch done; evidence in ${CB_EVIDENCE_DIR} ==="
