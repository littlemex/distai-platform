"""The one place `collect_status.py` is allowed to run a subprocess.

Everything else in this tool (plan parsing, status derivation, rendering) is a
pure function with no I/O. Status *collection* necessarily shells out to
`kubectl`/`aws`, so that one seam gets its own module with a structural
allowlist, instead of trusting a human to keep every call site read-only by
convention. This is checked by `tests/test_readonly_exec.py` with
`subprocess.run` mocked out — no real cluster/AWS access is needed to test it.
"""
from __future__ import annotations

import subprocess

_ALLOWED_KUBECTL_VERBS = {"get"}
_ALLOWED_AWS_EC2_VERBS = {
    "describe-capacity-reservations",
    "describe-instances",
}


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
    if program == "aws":
        if len(argv) < 3 or argv[1] != "ec2" or argv[2] not in _ALLOWED_AWS_EC2_VERBS:
            raise DisallowedCommandError(
                f"aws call must be 'aws ec2 <one of {sorted(_ALLOWED_AWS_EC2_VERBS)}>', got argv={argv!r}"
            )
        return
    raise DisallowedCommandError(f"program must be 'kubectl' or 'aws', got {program!r}")


def run_readonly(argv: list[str], timeout_seconds: int = 30) -> str:
    """Run an allowlisted, read-only kubectl/aws call and return its stdout.

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
