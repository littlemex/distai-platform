#!/usr/bin/env bash
# Re-pin vendor/awsome-distributed-ai/ to a newer upstream commit. Run this,
# never hand-edit a file under awsome-distributed-ai/ (tests/0.static.sh
# checks the result against the SHA256SUMS this script writes).
#
# Usage: update-vendor.sh <commit-sha>
set -euo pipefail

COMMIT="${1:?usage: update-vendor.sh <commit-sha>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SCRIPT_DIR}/awsome-distributed-ai"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

curl -fsSL "https://github.com/awslabs/awsome-distributed-ai/archive/${COMMIT}.tar.gz" \
    -o "${TMP}/src.tar.gz"
tar xzf "${TMP}/src.tar.gz" -C "${TMP}"
SRC_DIR=$(find "${TMP}" -maxdepth 1 -type d -name 'awsome-distributed-ai-*')
SRC="${SRC_DIR}/validation/gpu-cluster-healthcheck"
[[ -d "${SRC}" ]] || { echo "validation/gpu-cluster-healthcheck not found at ${COMMIT}" >&2; exit 1; }

rm -rf "${DEST}"
cp -R "${SRC}" "${DEST}"
rm -rf "${DEST}/slurm"
cp "${SRC_DIR}/LICENSE" "${DEST}/LICENSE"

if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=(sha256sum)
else
    SHA_CMD=(shasum -a 256)
fi
(cd "${SCRIPT_DIR}" && find awsome-distributed-ai -type f -print0 | sort -z | xargs -0 "${SHA_CMD[@]}" > SHA256SUMS)

cat > "${SCRIPT_DIR}/VENDORED_COMMIT" <<EOF
# Vendored from https://github.com/awslabs/awsome-distributed-ai
# Path: validation/gpu-cluster-healthcheck
# Commit: ${COMMIT}
# Date captured: $(date -u +%Y-%m-%d)
# License: see awsome-distributed-ai/LICENSE in this directory (MIT-style,
#   Copyright Amazon.com, Inc. or its affiliates).
#
# slurm/ was dropped from the vendored copy: this platform is Kubernetes-only
# (AGENTS.md section 3), and the Slurm integration is unused dead weight here.
# Everything else is byte-for-byte upstream. Do not hand-edit files under
# awsome-distributed-ai/ -- re-run this script against a new pinned commit
# instead, so the diff a reviewer sees is always "what upstream changed",
# never "what we changed inside someone else's file". SHA256SUMS (this
# directory) is what tests/0.static.sh actually checks.
EOF

echo "Re-pinned to ${COMMIT}. Review the diff, then commit vendor/ as one change."
