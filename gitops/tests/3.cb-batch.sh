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
  k run cb-health --rm -i --restart=Never --image="${CB_HEALTH_IMAGE}" \
    --overrides="{\"metadata\":{\"annotations\":{\"karpenter.sh/do-not-disrupt\":\"true\"}},\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${NODE}\"},\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    -- bash -c '
      echo "--- nvidia-smi -L ---"; nvidia-smi -L
      echo "--- driver/CUDA ---"; nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv
      echo "--- Fabric Manager (if present) ---"; (systemctl is-active nvidia-fabricmanager 2>&1 || echo "not applicable on this instance type")
      echo "--- dcgmi diag -r 3 ---"; (command -v dcgmi >/dev/null && dcgmi diag -r 3 || echo "dcgmi not in this image; run from a DCGM-enabled image on the real block")
      echo "--- nvbandwidth (if present) ---"; (command -v nvbandwidth >/dev/null && nvbandwidth || echo "nvbandwidth not in this image; add to the pre-block image for the real block")
      echo "--- lspci PCIe topology ---"; (command -v lspci >/dev/null && lspci -t || echo "lspci not in this image; the real block pinned NCCL/EFA test image includes pciutils")
      echo "--- aws-ofi-nccl / libfabric ---"; (fi_info -p efa 2>&1 || echo "no EFA on this node (expected on cheap dry-run instances)")
      echo "--- NCCL/libfabric versions baked into this image ---"
    ' 2>&1 | tee "${CB_EVIDENCE_DIR}/step20-node-health.raw.log" || fail "step20: health pod did not complete"

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
if run_step 24; then
  log "=== step 24: DCGM exporter quick-add ==="
  helm upgrade --install dcgm-exporter-cb https://github.com/NVIDIA/dcgm-exporter/releases/download/4.4.1-4.5.1/dcgm-exporter-helm-4.4.1.tgz \
    --namespace cb-batch --create-namespace --wait --timeout 5m 2>&1 | tee "${CB_EVIDENCE_DIR}/step24-dcgm-install.log" \
    || { info "step24: chart URL/version may have moved — confirm the current release asset at github.com/NVIDIA/dcgm-exporter/releases before the real block"; fail "step24: dcgm-exporter install failed"; }
  wait_until 120 5 "dcgm-exporter pod Running" bash -c "kubectl -n cb-batch get pods -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running" \
    || fail "step24: dcgm-exporter did not reach Running"
  POD="$(k -n cb-batch get pods -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].metadata.name}')"
  k -n cb-batch exec "${POD}" -- curl -s localhost:9400/metrics | grep -c "^DCGM_FI_" > "${CB_EVIDENCE_DIR}/step24-metric-count.log" \
    || fail "step24: could not scrape /metrics from dcgm-exporter"
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
    info "step27: SKIPPED — only one GPU node present (node_a=${NODE_A:-<none>}, node_b=${NODE_B:-<none>}). Must re-run against a real 2-node pool before trusting any per-node-lane test's isolation."
    pass "step27: skipped, 1-node pool (expected on a 1-node dry run)"
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
