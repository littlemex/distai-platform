#!/usr/bin/env bash
set -euo pipefail
gh run view --repo littlemex/distai-platform --job 139834322632 --log > gitops-fail-full-2.log
aws s3 cp gitops-fail-full-2.log s3://claudecode-776010787911-46188a9b/relay/dp-manual-out/gitops-fail-full-2.log --region us-east-1 --only-show-errors
