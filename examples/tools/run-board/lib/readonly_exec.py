"""The one place `collect_status.py` is allowed to run a subprocess.

Everything else in this tool (plan parsing, status derivation, rendering) is a
pure function with no I/O. Status *collection* necessarily shells out to
`kubectl`, so that one seam gets its own module with a structural allowlist,
instead of trusting a human to keep every call site read-only by convention.
This is checked by `tests/test_readonly_exec.py` with `subprocess.run` mocked
out — no real cluster access is needed to test it.

Only `kubectl get <resource> <name> -n <namespace> -o json` is allowlisted
today, because that is the exact shape this tool's two call sites
(`collect_status.py`'s `job` and `kueue_workload` status sources) ever
actually call — not merely `kubectl get` with anything after it (#63, filed
as #60 item 2: an earlier version of this guard checked only the verb, so
`kubectl get secrets -A -o json`, `--raw <path>`, `--as=<user>` or
`--kubeconfig <file>` all passed, none of which either call site reaches
today, but a future call site added without updating this guard would not
be stopped from reading more than this tool's own two calls need). The
resource allowlist (`_ALLOWED_RESOURCES`) is as narrow as the two call
sites: a future `capacity_reservation` status source over `aws
ec2 describe-*` is a natural extension (see collect_status.py's own
docstring), but an allowlist entry for a call nothing makes is a liability
(it looks safe to call, and nothing would notice if it quietly stopped
being read-only), not a feature.
"""
from __future__ import annotations

import subprocess

_ALLOWED_KUBECTL_VERBS = {"get"}
_ALLOWED_RESOURCES = {"job", "workloads.kueue.x-k8s.io"}
# Flags that widen a `kubectl get <resource> <name> -n <ns> -o json` call
# beyond "one named object in one namespace" (#60 item 2). `-A`/
# `--all-namespaces` reads every namespace; `--as`/`--as-group` impersonates
# a different identity; `--kubeconfig`/`--context`/`--cluster`/`--server`
# point at a different cluster than this credential's own; `--raw` bypasses
# the resource/name shape check entirely (it takes a literal API path, not a
# resource type).
_DISALLOWED_FLAG_PREFIXES = (
    "-A", "--all-namespaces",
    "--as", "--as-group", "--as-uid",
    "--kubeconfig", "--context", "--cluster", "--server",
    "--raw",
)


class DisallowedCommandError(ValueError):
    """Raised when a caller asks this wrapper to run something not on the allowlist."""


class CollectionError(RuntimeError):
    """A rejected-by-the-cluster read, distinguished from a missing object
    (#63, filed as #60 item 3): a plain `CalledProcessError` reports both a
    `NotFound` ("kubectl get job foo": no such Job, a normal outcome a plan
    item's own timing can produce) and a `Forbidden` ("the caller's own
    RBAC does not grant this read") as the same
    "CalledProcessError: ... returned non-zero exit status 1." with no
    `stderr`, so a misconfigured credential and a mistyped or
    not-yet-created object read identically in collect_status.py's own
    error list. `kind` is "not_found", "forbidden" or "other" (kubectl's
    own wording is matched, not parsed against the Kubernetes API's actual
    structured Status - adequate for distinguishing these three outcomes in
    a human-readable error list, not a guarantee against every possible
    kubectl stderr phrasing)."""

    def __init__(self, kind: str, stderr: str):
        self.kind = kind
        self.stderr = stderr
        super().__init__(f"{kind}: {stderr.strip()}")


def _check_argv(argv: list[str]) -> None:
    if not argv:
        raise DisallowedCommandError("empty argv")
    program = argv[0]
    if program != "kubectl":
        raise DisallowedCommandError(f"program must be 'kubectl', got {program!r}")
    if len(argv) < 2 or argv[1] not in _ALLOWED_KUBECTL_VERBS:
        raise DisallowedCommandError(
            f"kubectl verb must be one of {sorted(_ALLOWED_KUBECTL_VERBS)}, got argv={argv!r}"
        )
    if len(argv) < 3 or argv[2] not in _ALLOWED_RESOURCES:
        raise DisallowedCommandError(
            f"kubectl get's resource must be one of {sorted(_ALLOWED_RESOURCES)}, got argv={argv!r}"
        )
    for arg in argv:
        if any(arg == p or arg.startswith(p + "=") for p in _DISALLOWED_FLAG_PREFIXES):
            raise DisallowedCommandError(f"disallowed flag {arg!r} in argv={argv!r}")
    if "-n" not in argv:
        raise DisallowedCommandError(f"kubectl get must name a namespace with -n, got argv={argv!r}")
    if "-o" not in argv or "json" not in argv[argv.index("-o") + 1 : argv.index("-o") + 2]:
        raise DisallowedCommandError(f"kubectl get must request -o json, got argv={argv!r}")


def run_readonly(argv: list[str], timeout_seconds: int = 30) -> str:
    """Run an allowlisted, read-only kubectl call and return its stdout.

    Always an argv list, never `shell=True` — there is no shell to inject into.
    Raises DisallowedCommandError before anything is executed if `argv` is not
    on the allowlist, and CollectionError if the command itself fails (a
    missing resource, an expired credential, ...), distinguishing a
    `NotFound` from a `Forbidden` from anything else by kubectl's own stderr
    wording (see CollectionError's own docstring). Callers treat both
    DisallowedCommandError and CollectionError as "could not collect status
    for this item", never as a fatal error for the whole run (see
    collect_status.py's per-item try/except) — the distinction is for the
    error message a human reads, not for control flow.
    """
    _check_argv(argv)
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=True,
        )
    except subprocess.CalledProcessError as e:
        stderr = e.stderr or ""
        if "NotFound" in stderr:
            raise CollectionError("not_found", stderr) from e
        if "Forbidden" in stderr:
            raise CollectionError("forbidden", stderr) from e
        raise CollectionError("other", stderr or str(e)) from e
    return result.stdout
