#!/usr/bin/env python3
"""Compile a tiny, fixed model to a Neuron NEFF, with no Trainium/Inferentia
hardware present.

This is a toolchain smoke test, not a representativeness check: the model
is fixed in this file (see `build_example_model`) and nothing in this
repository ties it to any chart or example this platform ships -- none of
`examples/` currently has Trainium-specific model code. A pass means the
Neuron compiler toolchain installs and compiles *this* model on a
CPU-only host; it does not mean every operator this platform's own
workloads use would compile, and it does not replace the real-hardware
check in `gitops/tests/1.e2e.sh` (`GITOPS_RUN_ACCEL_E2E=1`), which is the
only check that proves a real trn2.3xlarge node and the Neuron device
plugin work end to end. It is still useful: a broken install of *this
exact toolchain* (the versions pinned in the workflow, not necessarily
the versions the real-hardware run's own container pins) or a regression
in *this exact API call* shows up here, cheaply, on every pull request,
instead of only in that paid, light-tier run.

Primary sources:

- https://awsdocs-neuron.readthedocs-hosted.com/en/latest/compiler/neuronx-cc/how-to-generate-neff.html
  ("A target instance family: one of trn1, trn1n, inf2, or trn2. You can run
  the compilation step on any EC2 instance or on-premises host.")
- https://awsdocs-neuron.readthedocs-hosted.com/en/latest/archive/frameworks/torch/torch-neuronx/api-reference-guide/inference/api-torch-neuronx-trace.html
  (`torch_neuronx.trace(..., cpu_backend=True, compiler_args=[...])`:
  "A boolean indicating whether CPU should be used for tracing. If set to
  True, tracing can be done completely on CPU. This keyword needs to be used
  with the compiler_args option to set the --target flag.")
- https://awsdocs-neuron.readthedocs-hosted.com/en/latest/torch/get-started/quickstart-build-first-model.html
  (`build_example_model`'s TinyMLP shape is taken from this quickstart's
  "Step 1: Run a model in eager mode"; that page's own example runs on
  real Trainium hardware, this one does not).

`import torch_neuronx` alone (before `cpu_backend` ever comes into play)
pulls in `torch_xla`, which goes on to `ctypes.CDLL` a PJRT plugin library
that dynamically links `libnrt.so.1` -- found across four real runs of
this check on a GitHub-hosted runner, all on 2026-11-26:

1. Without `aws-neuronx-runtime-lib` installed at all, `libneuronxla`'s own
   `libnrt.py` (`check_compatible_libnrt()`, read from the installed
   package's source, `libneuronxla==2.2.17544.0+fb9962bf`) raised `OSError`
   itself, before the native loader was even reached, unless
   `NEURON_INTERNAL_SKIP_LIBNRT_CHECK=1` was set first (an internal,
   undocumented switch found only by reading that source file).
2. With that switch set but the runtime library still not installed, the
   native loader itself (`ctypes.CDLL`) raised `OSError: libnrt.so.1:
   cannot open shared object file`, from `torch_neuronx`'s own
   `xla.init()` -> `enable_neuron_custom_calls()`. Installing
   `aws-neuronx-runtime-lib` (see the workflow's own install step) fixed
   this one.
3. A third run went past both of those and produced a real NEFF, then
   failed in `torch.jit.save()`/`torch.jit.load()` (not in `trace()`
   itself, and not in anything this file still does):
   `torch.jit.load()` went on to initialize the Neuron Runtime and failed
   with no device present. That round-trip was removed; this check now
   stops at confirming the `.neff` file `trace()` already wrote.
4. A fourth run, with `NEURON_INTERNAL_SKIP_LIBNRT_CHECK` removed again
   and `aws-neuronx-runtime-lib` installed, passed: once the library is
   on disk, `check_compatible_libnrt()`'s own path check passes on its
   own, and that switch is not needed. It is not set anywhere in this
   file; the only fix carried forward from finding 1 is installing the
   library itself.

Usage:
    neuron_cpu_compile_check.py [--target TARGET]

Exits 0 once a non-empty .neff file has been confirmed on disk; exits 1
with a GitHub Actions error annotation on any failure (import, trace, or
the file not being there).
"""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path


def error(message: str) -> None:
    for line in message.splitlines() or [""]:
        print(f"::error::{line}", file=sys.stderr)


def build_example_model() -> tuple[object, tuple[object, ...]]:
    """A tiny two-layer MLP, deliberately minimal and fixed.

    See the module docstring: this shape is taken from the Neuron SDK's
    own quickstart, chosen only because it is small enough to compile in a
    few seconds on a shared CI runner, and is not a stand-in for anything
    this platform ships for Trainium.
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
    except Exception as exc:  # noqa: BLE001 - an import-time OSError is a documented failure mode here, not only ImportError
        error(f"could not import torch / torch_neuronx: {exc}")
        return 1

    print(f"torch {torch.__version__}, torch_neuronx {torch_neuronx.__version__}")
    print(f"compiling for --target {args.target} with cpu_backend=True (no Neuron device on this host)")

    try:
        model, example_inputs = build_example_model()
    except Exception as exc:  # noqa: BLE001
        error(f"build_example_model() failed: {exc}")
        return 1

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

        if traced is None:
            error("torch_neuronx.trace() returned None without raising")
            return 1

        # Deliberately stops here, at the NEFF trace() already wrote to
        # disk. See the module docstring's third finding for why a
        # torch.jit.save()/torch.jit.load() round-trip was tried and
        # removed: torch.jit.load() itself goes on to initialize the
        # Neuron Runtime, which is real-hardware territory this check has
        # no business depending on.
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

    print("OK: compiled a tiny model to a NEFF with no Neuron device present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
