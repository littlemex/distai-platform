import subprocess
import sys
from pathlib import Path
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.readonly_exec import CollectionError, DisallowedCommandError, run_readonly  # noqa: E402


@pytest.mark.parametrize(
    "argv",
    [
        ["kubectl", "delete", "pod", "x"],
        ["kubectl", "apply", "-f", "x.yaml"],
        ["kubectl", "patch", "deployment", "x"],
        ["kubectl"],
        ["aws", "ec2", "terminate-instances", "--instance-ids", "i-1"],
        ["aws", "ec2", "run-instances"],
        ["aws", "s3", "cp", "a", "b"],
        ["aws", "ec2", "describe-capacity-reservations"],  # not wired to anything in this tool; see readonly_exec.py
        ["aws"],
        ["rm", "-rf", "/"],
        ["sh", "-c", "kubectl get pods"],
        [],
        # #63, filed as #60 item 2: the guard used to check only the verb
        # ("kubectl get"), so every one of these passed through.
        ["kubectl", "get", "secrets", "-A", "-o", "json"],
        ["kubectl", "get", "secrets", "my-secret", "-n", "ns", "-o", "json"],  # resource not on the allowlist
        ["kubectl", "get", "pods", "-n", "ns", "-o", "json"],  # resource not on the allowlist
        ["kubectl", "get", "job", "x", "-n", "ns", "-o", "json", "--as", "admin"],
        ["kubectl", "get", "job", "x", "-n", "ns", "-o", "json", "--as-group=system:masters"],
        ["kubectl", "get", "job", "x", "--raw", "/api/v1/namespaces/ns/pods"],
        ["kubectl", "get", "job", "x", "-n", "ns", "-o", "json", "--kubeconfig", "/tmp/other"],
        ["kubectl", "get", "job", "x", "-n", "ns", "-o", "json", "--context", "other-cluster"],
        ["kubectl", "get", "job", "x", "-o", "json"],  # no -n
        ["kubectl", "get", "job", "x", "-n", "ns"],  # no -o json
        ["kubectl", "get", "job", "x", "-n", "ns", "-o", "yaml"],  # -o, but not json
    ],
)
def test_disallowed_commands_never_reach_subprocess(argv):
    with mock.patch("subprocess.run") as run:
        with pytest.raises(DisallowedCommandError):
            run_readonly(argv)
        run.assert_not_called()


@pytest.mark.parametrize(
    "argv",
    [
        ["kubectl", "get", "job", "x", "-n", "ns", "-o", "json"],
        ["kubectl", "get", "workloads.kueue.x-k8s.io", "x", "-n", "ns", "-o", "json"],
    ],
)
def test_allowed_commands_are_passed_through_as_argv(argv):
    with mock.patch("subprocess.run") as run:
        run.return_value = mock.Mock(stdout="{}")
        out = run_readonly(argv)
        assert out == "{}"
        called_args, called_kwargs = run.call_args
        assert called_args[0] == argv
        assert called_kwargs.get("shell", False) is False, "must never use a shell"


@pytest.mark.parametrize(
    ("stderr", "expected_kind"),
    [
        ('Error from server (NotFound): jobs.batch "x" not found', "not_found"),
        ('Error from server (Forbidden): jobs.batch is forbidden: User "x" cannot get resource "jobs"', "forbidden"),
        ("Unable to connect to the server: dial tcp: i/o timeout", "other"),
    ],
)
def test_collection_error_classifies_kubectl_stderr(stderr, expected_kind):
    # #63, filed as #60 item 3: a missing object and a permission denial
    # used to read identically (the same CalledProcessError with no
    # stderr surfaced); this asserts the classification a caller
    # (collect_status.py) builds its own message from.
    argv = ["kubectl", "get", "job", "x", "-n", "ns", "-o", "json"]
    with mock.patch("subprocess.run") as run:
        run.side_effect = subprocess.CalledProcessError(returncode=1, cmd=argv, stderr=stderr)
        with pytest.raises(CollectionError) as exc_info:
            run_readonly(argv)
        assert exc_info.value.kind == expected_kind
        assert exc_info.value.stderr == stderr
