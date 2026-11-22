#!/usr/bin/env python3
"""Run ``vllm bench serve`` in this process with garbage collection off.

A collector pause in the load generator lands in the results as a spurious
inter-token gap or a late send. ``vllm bench serve`` has no switch for this,
so this wrapper imports vLLM's own CLI, collects once, freezes every object
that exists so far (``gc.freeze``) and disables the collector
(``gc.disable``) before the benchmark starts. Reference counting still frees
memory; only the cyclic collector is off, for one bounded run.

Usage: driver.py bench serve [vllm bench serve arguments...]
"""

import gc
import os
import sys

# vLLM can hand `bench serve` to a separate binary with os.execv; the
# collector settings below only hold while the Python implementation runs.
os.environ["VLLM_USE_RUST_BENCH"] = "0"

from vllm.entrypoints.cli.main import main  # noqa: E402

if __name__ == "__main__":
    if sys.argv[1:3] != ["bench", "serve"]:
        sys.exit("driver.py: usage: driver.py bench serve [arguments...]")
    sys.argv = ["vllm", *sys.argv[1:]]
    gc.collect()
    gc.freeze()
    gc.disable()
    main()
