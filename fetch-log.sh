#!/usr/bin/env bash
set -euo pipefail
gh run view --repo littlemex/distai-platform --job 139830151312 --log > foundation-fail-full.log
gh run view --repo littlemex/distai-platform --job 139830151158 --log > gitops-fail-full.log
aws s3 cp foundation-fail-full.log s3://claudecode-776010787911-46188a9b/relay/dp-manual-out/foundation-fail-full.log --region us-east-1 --only-show-errors
aws s3 cp gitops-fail-full.log s3://claudecode-776010787911-46188a9b/relay/dp-manual-out/gitops-fail-full.log --region us-east-1 --only-show-errors
