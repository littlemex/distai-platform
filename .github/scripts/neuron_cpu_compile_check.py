#!/usr/bin/env python3
"""Compile a tiny model to a Neuron NEFF, with no Trainium/Inferentia hardware present.

This is a static (CPU-only) check: it never touches a real accelerator, never
talks to AWS, and does not replace the real-hardware check in
`gitops/tests/1.e2e.sh` (`GITOPS_RUN_ACCEL_E2E=1`). It catches the class of
defect a CPU host CAN catch before any real-hardware run: an unsupported
operator, a compiler crash, or a broken Neuron toolchain install -- cheaply,
on every pull request.

Primary source for "compilation needs no Trainium/Inferentia hardware":

- https://awsdocs-neuron.readthedocs-hosted.com/en/latest/compiler/neuronx-cc/how-to-generate-neff.html
  ("A target instance family: one of trn1, trn1n, inf2, or trn2. You can run
  the compilation step on any EC2 instance or on-premises host.")
- https://awsdocs-neuron.readthedocs-hosted.com/en/latest/archive/frameworks/torch/torch-neuronx/api-reference-guide/inference/api-torch-neuronx-trace.html
  (`torch_neuronx.trace(..., cpu_backend=True, compiler_args=[...])`:
  "A boolean indicating whether CPU should be used for tracing. If set to
  True, tracing can be done completely on CPU. This keyword needs to be used
  with the compiler_args option to set the --target flag.")

`import torch_neuronx` alone (before `cpu_backend` ever comes into play)
pulls in `torch_xla`, which probes for the real Neuron runtime shared
library (`/opt/aws/neuron/lib/libnrt.so.1`) at import time and raises
`OSError` if it is absent -- confirmed on a real run of this check on a
GitHub-hosted runner (2026-11-26) with no such library installed (by
design: this check never installs the Neuron driver or runtime, see the
workflow's own header comment). `libneuronxla`'s own `libnrt.py`
(`check_compatible_libnrt()`, read from the installed package's source,
`libneuronxla==2.2.17544.0+fb9962bf` at the time this was found) honors
`NEURON_INTERNAL_SKIP_LIBNRT_CHECK=1` to skip exactly this probe, which is
set below before the import for exactly that reason.

Usage:
    neuron_cpu_compile_check.py [--target TARGET]

Exits 0 with a non-empty .neff file written to a temporary directory on
success; exits 1 with a GitHub Actions error annotation on any failure
(import or trace).
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

# Must be set before `import torch_neuronx` (see the module docstring):
# that import chain checks for the real Neuron runtime library and raises
# OSError if it is not installed, which is always true on this CPU-only
# runner.
os.environ.setdefault("NEURON_INTERNAL_SKIP_LIBNRT_CHECK", "1")


def error(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)


def build_example_model() -> tuple[object, tuple[object, ...]]:
    """A tiny two-layer MLP, deliberately minimal.

    This is not a stand-in for any model this platform's example charts run
    (none of `examples/` currently ships Trainium-specific model code, see
    the issue this check was added under); it exists only to exercise the
    Neuron compiler's tracing and lowering path end to end with a model
    small enough to compile in a few seconds on a shared CI runner. Its
    shape matches the AWS Neuron SDK's own "build your first model"
    quickstart tutorial, cited above.
    """
    import torch
    import torch.nn as nn

    class TinyMLP(nn.Module):
        def __init__(self, d_in: int = 128, d_hidden: int = 256, d_out: int = 10) -> None:
            super().__init__()
            self.stem = nn.Linear(d_in, d_hidden)
            self.act = nn.ReLU()
            self.head = nn.Linear(d_hidden, d_out)

        def forward(self, x: "torch.Tensor") -> "torch.Tensor":
            return self.head(self.act(self.stem(x)))

    model = TinyMLP().eval()
    example_inputs = (torch.randn(8, 128, dtype=torch.float32),)
    return model, example_inputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target",
        default="trn2",
        choices=["trn1", "trn1n", "inf2", "trn2"],
        help="Neuron target instance family to compile for (default: trn2).",
    )
    args = parser.parse_args()

    try:
        import torch
        import torch_neuronx
    except ImportError as exc:
        error(f"could not import torch / torch_neuronx: {exc}")
        return 1

    print(f"torch {torch.__version__}, torch_neuronx {torch_neuronx.__version__}")
    print(f"compiling for --target {args.target} with cpu_backend=True (no Neuron device on this host)")

    model, example_inputs = build_example_model()

    with tempfile.TemporaryDirectory(prefix="neuron-cpu-compile-") as workdir:
        try:
            traced = torch_neuronx.trace(
                model,
                example_inputs,
                compiler_workdir=workdir,
                compiler_args=["--target", args.target],
                cpu_backend=True,
            )
        except Exception as exc:  # noqa: BLE001 - surfaced as a CI failure either way
            error(f"torch_neuronx.trace(cpu_backend=True) failed: {exc}")
            return 1

        neff_candidates = sorted(Path(workdir).rglob("*.neff"))
        if not neff_candidates:
            error(f"trace() returned without raising, but no .neff file was written under {workdir}")
            return 1
        for neff in neff_candidates:
            size = neff.stat().st_size
            print(f"NEFF written: {neff} ({size} bytes)")
            if size == 0:
                error(f"{neff} is empty")
                return 1

        # Deliberately stops here, at the NEFF on disk. torch.jit.save()
        # followed by torch.jit.load() was tried as an extra round-trip
        # check and, on a real run of this workflow (2026-11-26), made
        # torch.jit.load() itself initialize the Neuron Runtime (NRT) --
        # which fails with no device present, exactly the failure this
        # check exists to avoid depending on. The traced ScriptModule's
        # embedded neuron::Model op is apparently prepared for execution
        # at load time, not purely deserialized; that is real-hardware
        # territory and out of scope for a CPU-only compile check.
        if traced is None:
            error("torch_neuronx.trace() returned None")
            return 1

    print("OK: compiled a tiny model to a NEFF with no Neuron device present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
