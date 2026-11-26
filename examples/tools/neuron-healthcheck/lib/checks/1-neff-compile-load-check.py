#!/usr/bin/env python3
"""Check 1: compile a tiny, fixed model to a NEFF AND load and run it on the
real Neuron device.

`torch_neuronx.trace()` is called without `cpu_backend=True`, because real
Trainium hardware is present: the model is compiled to a NEFF, then the
traced module is executed once on the example input. That execution goes
through the Neuron Runtime onto the device, which is what proves the
container's Neuron Runtime and the node's Neuron driver work together (an
`nrt_init` ABI mismatch between the two fails here). The CPU-only compile
check in `.github/scripts/neuron_cpu_compile_check.py` (issues #78/#79)
cannot reach this step: it has no device to load onto.

This is a toolchain smoke test on one fixed tiny model, not a
representativeness check. A pass means this exact model compiles, loads
and runs on this node with this image; it does not mean every operator
this platform's workloads use would compile.

The output is checked for shape only. Its numerical difference from the
same model run eagerly on CPU is printed and recorded as evidence, but not
asserted: the compiler may lower fp32 matrix multiplies to a narrower type
by default, and this check sets no tolerance it could defend.

Environment: RESULTS_DIR (where check-1-neff-compile-load.json is written),
NODE_NAME and INSTANCE_TYPE (copied into the result, optional).

Exit status: 0 PASS, 1 FAIL. PASS/FAIL lines go to stdout/stderr.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import tempfile
import traceback
from pathlib import Path

CHECK_NAME = "1-neff-compile-load"
EXPECTED_OUTPUT_SHAPE = (8, 10)


def write_result(status: str, message: str, evidence: str = "") -> None:
    """Same result schema as lib/common.sh's write_result()."""
    results_dir = os.environ.get("RESULTS_DIR", "")
    if not results_dir:
        print(f"[{CHECK_NAME}] RESULTS_DIR is not set; no result file written", file=sys.stderr)
        return
    Path(results_dir).mkdir(parents=True, exist_ok=True)
    doc = {
        "check": CHECK_NAME,
        "status": status,
        "message": message,
        "evidence": evidence,
        "node": os.environ.get("NODE_NAME", ""),
        "instance_type": os.environ.get("INSTANCE_TYPE", ""),
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    with open(os.path.join(results_dir, f"check-{CHECK_NAME}.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")


def fail(message: str, evidence: str = "") -> int:
    print(f"FAIL: {CHECK_NAME}: {message}", file=sys.stderr)
    if evidence:
        print(evidence, file=sys.stderr)
    write_result("FAIL", message, evidence)
    return 1


def build_example_model() -> tuple[object, tuple[object, ...]]:
    """A tiny two-layer MLP, deliberately minimal and fixed."""
    # Same shape as .github/scripts/neuron_cpu_compile_check.py's build_example_model(); change both together.
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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
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
    except Exception:  # noqa: BLE001 - an import-time OSError is a real failure mode, not only ImportError
        return fail("could not import torch / torch_neuronx", traceback.format_exc())

    versions = f"torch={torch.__version__} torch_neuronx={getattr(torch_neuronx, '__version__', 'unknown')}"
    print(f"[INFO] {versions}")

    try:
        model, example_inputs = build_example_model()
    except Exception:  # noqa: BLE001
        return fail("build_example_model() failed", traceback.format_exc())

    with tempfile.TemporaryDirectory(prefix="neuron-healthcheck-compile-") as workdir:
        try:
            traced = torch_neuronx.trace(
                model,
                example_inputs,
                compiler_workdir=workdir,
                compiler_args=["--target", args.target],
            )
        except Exception:  # noqa: BLE001
            return fail("torch_neuronx.trace() (compile) failed", traceback.format_exc())

        if traced is None:
            return fail("torch_neuronx.trace() returned None without raising")

        neff_candidates = sorted(Path(workdir).rglob("*.neff"))
        if not neff_candidates:
            return fail(f"trace() returned without raising, but no .neff file was written under {workdir}")
        neff_lines = []
        for neff in neff_candidates:
            size = neff.stat().st_size
            line = f"NEFF written: {neff.relative_to(workdir)} ({size} bytes)"
            print(line)
            neff_lines.append(line)
            if size == 0:
                return fail(f"{neff} is empty", "\n".join(neff_lines))

        # The "load" half: execute the compiled NEFF on the device. Any
        # Neuron Runtime error (nrt_init included) surfaces as an exception
        # here and is this check's failure.
        try:
            with torch.no_grad():
                out = traced(*example_inputs)
        except Exception:  # noqa: BLE001
            return fail(
                "running the traced model on the Neuron device failed (Neuron Runtime load/execute)",
                "\n".join(neff_lines) + "\n" + traceback.format_exc(),
            )

        if isinstance(out, (tuple, list)) and len(out) == 1:
            out = out[0]
        if not isinstance(out, torch.Tensor):
            return fail(f"traced model returned {type(out).__name__}, not a tensor", "\n".join(neff_lines))
        shape = tuple(out.shape)
        if shape != EXPECTED_OUTPUT_SHAPE:
            return fail(f"output shape {shape} != expected {EXPECTED_OUTPUT_SHAPE}", "\n".join(neff_lines))

        try:
            with torch.no_grad():
                reference = model(*example_inputs)
            max_abs_diff = f"{(out.float().cpu() - reference).abs().max().item():.6g}"
        except Exception as exc:  # noqa: BLE001 - informational only
            max_abs_diff = f"not computed ({exc})"

    evidence = "\n".join([versions, *neff_lines, f"output shape {shape}", f"max |device - cpu eager| = {max_abs_diff} (recorded, not asserted)"])
    message = f"compiled a NEFF for --target {args.target}, loaded and ran it on the device, output shape {shape}"
    print(f"PASS: {CHECK_NAME}: {message}")
    print(evidence)
    write_result("PASS", message, evidence)
    return 0


if __name__ == "__main__":
    sys.exit(main())
