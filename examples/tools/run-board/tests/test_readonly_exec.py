import sys
from pathlib import Path
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.readonly_exec import DisallowedCommandError, run_readonly  # noqa: E402


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
        ["aws", "ec2", "describe-capacity-reservations"],  # not wired to anything in this PR; see readonly_exec.py
        ["aws"],
        ["rm", "-rf", "/"],
        ["sh", "-c", "kubectl get pods"],
        [],
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
