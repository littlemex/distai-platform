#!/usr/bin/env bash
# Unit tests for the run-board example tool. No AWS credentials, no cluster access,
# no network access beyond resolving the two pinned Python packages below — every
# test uses fixture JSON/YAML under tests/ and tests/fixtures/, and mocks out
# lib.readonly_exec.run_readonly rather than ever calling a real kubectl/aws.
#
# Run via the distai-platform EC2 runner, never on a developer Mac:
#   runner/run.sh --ref <branch or main> -- bash examples/tools/run-board/tests/run_tests.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

echo "[run-board tests] python: $(python3 --version)"
uv run -q --with pytest==8.3.4 --with PyYAML==6.0.2 python -m pytest tests/ -v
