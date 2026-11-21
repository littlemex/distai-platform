"""The one place `collect_status.py` is allowed to run a subprocess.

Everything else in this tool (plan parsing, status derivation, rendering) is a
pure function with no I/O. Status *collection* necessarily shells out to
`kubectl`, so that one seam gets its own module with a structural allowlist,
instead of trusting a human to keep every call site read-only by convention.
This is checked by `tests/test_readonly_exec.py` with `subprocess.run` mocked
out — no real cluster access is needed to test it.

Only `kubectl get` is allowlisted today, because that is the only thing this
tool's two call sites (`collect_status.py`'s `job` and `kueue_workload` status
sources) ever actually call. An `aws ec2 describe-*` branch is a natural
extension for a future `capacity_reservation` status source, but is not added
here speculatively — an allowlist entry for a call nothing makes is a
liability (it looks safe to call, and nothing would notice if it quietly
stopped being read-only), not a feature.
"""
from __future__ import annotations

import subprocess

_ALLOWED_KUBECTL_VERBS = {"get"}


class DisallowedCommandError(ValueError):
    """Raised when a caller asks this wrapper to run something not on the allowlist."""


def _check_argv(argv: list[str]) -> None:
    if not argv:
        raise DisallowedCommandError("empty argv")
    program = argv[0]
    if program == "kubectl":
        if len(argv) < 2 or argv[1] not in _ALLOWED_KUBECTL_VERBS:
            raise DisallowedCommandError(
                f"kubectl verb must be one of {sorted(_ALLOWED_KUBECTL_VERBS)}, got argv={argv!r}"
            )
        return
    raise DisallowedCommandError(f"program must be 'kubectl', got {program!r}")


def run_readonly(argv: list[str], timeout_seconds: int = 30) -> str:
    """Run an allowlisted, read-only kubectl call and return its stdout.

    Always an argv list, never `shell=True` — there is no shell to inject into.
    Raises DisallowedCommandError before anything is executed if `argv` is not
    on the allowlist, and `subprocess.CalledProcessError` if the command itself
    fails (a missing resource, an expired credential, ...). Callers treat both
    as "could not collect status for this item", never as a fatal error for
    the whole run (see collect_status.py's per-item try/except).
    """
    _check_argv(argv)
    result = subprocess.run(
        argv,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
        check=True,
    )
    return result.stdout
