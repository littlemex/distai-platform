#!/usr/bin/env python3
"""Cross-check every `pool.startupTaints` entry a cell actually ships, and
every device-plugin add-on's own tolerations, against the one key/effect
`vigil-controller` is configured to watch (issue #96).

Root cause this closes: `capacity-pool`'s chart stays generic on purpose --
it renders whatever `pool.startupTaints` it is given, and does not know
`vigil-controller` exists at all (the chart-level design decision recorded
on issue #96); the four device-plugin add-ons each carry their own, separately
written `tolerations` value for the same reason. Nothing else in this
repository catches either half drifting from the other: a
`pool.startupTaints` entry whose `key`/`effect` is not what
`gitops/addons/vigil-controller/addon.yaml`'s own `values.config.taintKey`/
`.taintEffect` names, or a device-plugin add-on whose own tolerations no
longer include that key, is a taint no controller in this platform ever
removes and no DaemonSet can tolerate -- not even at a timeout, since
`vigil-controller` only acts on the one key/effect it is configured with,
and a Pod that cannot tolerate the real taint cannot schedule regardless.
This check catches that drift before it wedges a real node, permanently,
with no automatic recovery. It is a render-time, cross-file check
precisely because `helm lint`/`helm template` on any one of these files
alone cannot see the others at all.

Checked:
  - `vigil-controller`'s own `values.config.taintKey`/`.taintEffect` are
    both set, and `values.config.knownStartupTaintKeys` (a list) contains
    that same `taintKey` (the chart's own `config.example.yaml`: "Must
    include taintKey itself" -- this add-on's own values could omit it).
  - every `gitops/cells/*/capacity-pool/*.yaml`'s `pool.startupTaints[].key`/
    `.effect` matches `vigil-controller`'s configured `taintKey`/`.taintEffect`.
  - every one of `accel-nvidia-device-plugin`'s `values.tolerations`,
    `accel-neuron-device-plugin`'s `values.devicePlugin.tolerations`,
    `accel-efa-device-plugin-nvidia`'s and `accel-efa-device-plugin-neuron`'s
    `values.tolerations` contains an entry whose `key`/`effect` matches
    `vigil-controller`'s configured `taintKey`/`.taintEffect`.
  - no `gitops/cells/*/capacity-pool/*.yaml` combines a non-empty
    `pool.startupTaints` with `accelerator.methodLabel.value: dra`: the
    DRA advertisers (`accel-nvidia-dra`/`accel-neuron-dra`) do not
    tolerate this key, and no real dynamically-provisioned DRA pool
    exists to verify that combination against (#19 E2/E4c).

What this check does NOT do (left to `check_startup_taint_renders.py`,
a separate, network-requiring check in the same style as
`check_pinned_crds.py`): render any chart and read the *rendered*
ConfigMap/DaemonSet back -- this check only reads each `addon.yaml`'s own
declared `values:`, so a chart-level templating bug that renders
something other than what `values:` says (for example a `config.*` key
the chart silently ignores) is not caught here.

Usage: check_startup_taint_keys.py <repo_root> | check_startup_taint_keys.py --selftest
Prints one PASS/FAIL line per check; exits 1 if any failed.
"""
from __future__ import annotations

import glob
import os
import sys

import yaml

FAILURES: list[str] = []

# gitops/addons/<name>/addon.yaml -> dotted path to its own tolerations list,
# for the four device-plugin add-ons #96 added the shared taint toleration
# to. Each path is read the same way `values.<path>` would be in that
# add-on's own addon.yaml (a list of {key, effect, ...}).
DEVICE_PLUGIN_TOLERATIONS_PATHS = {
    "accel-nvidia-device-plugin": "tolerations",
    "accel-neuron-device-plugin": "devicePlugin.tolerations",
    "accel-efa-device-plugin-nvidia": "tolerations",
    "accel-efa-device-plugin-neuron": "tolerations",
}


def check(label: str, condition: bool, reason: str = "") -> None:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    return doc if isinstance(doc, dict) else {}


def get_path(d: dict, dotted: str):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def main(repo_root: str) -> int:
    vigil_path = os.path.join(repo_root, "gitops/addons/vigil-controller/addon.yaml")
    if not os.path.isfile(vigil_path):
        check("gitops/addons/vigil-controller/addon.yaml exists", False, "not found")
        return 1
    vigil = load(vigil_path)
    vigil_config = get_path(vigil, "values.config")
    vigil_config = vigil_config if isinstance(vigil_config, dict) else {}
    taint_key = vigil_config.get("taintKey")
    taint_effect = vigil_config.get("taintEffect")
    known_keys = vigil_config.get("knownStartupTaintKeys")
    known_keys = known_keys if isinstance(known_keys, list) else []
    check("vigil-controller's values.config.taintKey is set", bool(taint_key), f"got {taint_key!r}")
    check("vigil-controller's values.config.taintEffect is set", bool(taint_effect), f"got {taint_effect!r}")
    check(
        "vigil-controller's values.config.knownStartupTaintKeys (a list) contains its own taintKey",
        isinstance(vigil_config.get("knownStartupTaintKeys"), list) and taint_key in known_keys,
        f"taintKey={taint_key!r} knownStartupTaintKeys={vigil_config.get('knownStartupTaintKeys')!r}"
        " (must be a list containing taintKey, not a bare string)",
    )
    if not (taint_key and taint_effect):
        return 1 if FAILURES else 0

    # --- every cell's pool.startupTaints
    cell_files = sorted(glob.glob(os.path.join(repo_root, "gitops/cells/*/capacity-pool/*.yaml")))
    checked_any_startup_taint = False
    for path in cell_files:
        rel = os.path.relpath(path, repo_root)
        doc = load(path)
        pool = get_path(doc, "values.pool")
        startup_taints = pool.get("startupTaints") if isinstance(pool, dict) else None
        method_label_value = get_path(doc, "values.accelerator.methodLabel.value")
        if startup_taints and method_label_value == "dra":
            # #19's own E2/E4c: a dynamically provisioned DRA pool never
            # initializes at all; a static NodePool for the DRA method is
            # #27's own future scope. No real pool reaches this combination
            # today, but nothing else refuses it either -- refused here so
            # "no such pool exists today" stays true rather than becoming
            # stale the day one is added with no accel-*-dra toleration to
            # match it.
            check(
                f"{rel} does not combine accelerator.methodLabel value 'dra' with pool.startupTaints",
                False,
                "the DRA advertisers (accel-nvidia-dra/accel-neuron-dra) do not tolerate this taint "
                "(#19 E2/E4c: no real dynamically-provisioned DRA pool exists to verify it against) "
                "-- this node would wait the full timeout on every launch",
            )
        for i, t in enumerate(startup_taints or []):
            checked_any_startup_taint = True
            if not isinstance(t, dict):
                check(f"{rel}'s pool.startupTaints[{i}] is a mapping", False, f"got {t!r}")
                continue
            key, effect = t.get("key"), t.get("effect")
            check(
                f"{rel}'s pool.startupTaints[{i}].key ({key!r}) matches vigil-controller's taintKey ({taint_key!r})",
                key == taint_key,
                f"got key={key!r}; vigil-controller only watches {taint_key!r}, so this taint would never be removed by anything",
            )
            check(
                f"{rel}'s pool.startupTaints[{i}].effect ({effect!r}) matches vigil-controller's taintEffect ({taint_effect!r})",
                effect == taint_effect,
                f"got effect={effect!r}; vigil-controller only watches effect {taint_effect!r}, so this taint would never be removed by anything",
            )
    if not checked_any_startup_taint:
        print("INFO no gitops/cells/*/capacity-pool/*.yaml sets pool.startupTaints yet (the mechanism ships opt-in, issue #96)")

    # --- every device-plugin add-on's own tolerations
    for name, tol_path in DEVICE_PLUGIN_TOLERATIONS_PATHS.items():
        addon_path = os.path.join(repo_root, "gitops/addons", name, "addon.yaml")
        rel = os.path.relpath(addon_path, repo_root)
        if not os.path.isfile(addon_path):
            check(f"{rel} exists", False, "not found")
            continue
        doc = load(addon_path)
        tolerations = get_path(doc, f"values.{tol_path}")
        tolerations = tolerations if isinstance(tolerations, list) else []
        matches = [
            t for t in tolerations
            if isinstance(t, dict) and t.get("key") == taint_key and t.get("effect") == taint_effect
        ]
        check(
            f"{rel}'s values.{tol_path} tolerates vigil-controller's {taint_key}:{taint_effect}",
            len(matches) >= 1,
            f"got {tolerations!r} -- this DaemonSet could never become Ready while the startup taint is present, "
            "so vigil-controller would only ever remove it at its own timeout",
        )

    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all startup-taint-key checks passed")
    return 0


# ------------------------------------------------------------- selftest
#
# A check that has only ever been seen green is not trusted to actually
# fail on the thing it claims to catch (this one, before this selftest
# existed, had never failed: no tracked file gives it anything to reject).
# Each case below builds a minimal, otherwise-valid fixture tree, breaks
# exactly one rule, and asserts the resulting FAILURES mention that rule's
# own label substring.


def _write(root: str, rel: str, doc: dict) -> None:
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f)


def _baseline(root: str) -> None:
    _write(root, "gitops/addons/vigil-controller/addon.yaml", {
        "addon": "vigil-controller",
        "values": {
            "config": {
                "taintKey": "distai.dev/startup-not-ready",
                "taintEffect": "NoSchedule",
                "knownStartupTaintKeys": ["distai.dev/startup-not-ready"],
            },
        },
    })
    _write(root, "gitops/addons/accel-nvidia-device-plugin/addon.yaml", {
        "addon": "accel-nvidia-device-plugin",
        "values": {"tolerations": [{"key": "distai.dev/startup-not-ready", "effect": "NoSchedule"}]},
    })
    _write(root, "gitops/addons/accel-neuron-device-plugin/addon.yaml", {
        "addon": "accel-neuron-device-plugin",
        "values": {"devicePlugin": {"tolerations": [{"key": "distai.dev/startup-not-ready", "effect": "NoSchedule"}]}},
    })
    _write(root, "gitops/addons/accel-efa-device-plugin-nvidia/addon.yaml", {
        "addon": "accel-efa-device-plugin-nvidia",
        "values": {"tolerations": [{"key": "distai.dev/startup-not-ready", "effect": "NoSchedule"}]},
    })
    _write(root, "gitops/addons/accel-efa-device-plugin-neuron/addon.yaml", {
        "addon": "accel-efa-device-plugin-neuron",
        "values": {"tolerations": [{"key": "distai.dev/startup-not-ready", "effect": "NoSchedule"}]},
    })
    _write(root, "gitops/cells/good-cell/capacity-pool/gpu.yaml", {
        "addon": "capacity-pool-gpu",
        "values": {"pool": {"name": "gpu", "startupTaints": [{"key": "distai.dev/startup-not-ready", "effect": "NoSchedule"}]}},
    })


def _run(root: str) -> tuple[int, list[str]]:
    global FAILURES
    FAILURES = []
    import contextlib
    import io

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = main(root)
    return rc, list(FAILURES)


def selftest() -> int:
    import shutil
    import tempfile

    cases: list[tuple[str, callable, str | None]] = []

    def case(name, mutate, expect_substr):
        cases.append((name, mutate, expect_substr))

    case("baseline passes with zero failures", lambda root: None, None)
    case(
        "a cell's pool.startupTaints with the wrong key fails only the key rule",
        lambda root: _write(root, "gitops/cells/good-cell/capacity-pool/gpu.yaml", {
            "addon": "capacity-pool-gpu",
            "values": {"pool": {"name": "gpu", "startupTaints": [{"key": "distai.dev/wrong-key", "effect": "NoSchedule"}]}},
        }),
        "matches vigil-controller's taintKey",
    )
    case(
        "a cell's pool.startupTaints with the wrong effect fails only the effect rule",
        lambda root: _write(root, "gitops/cells/good-cell/capacity-pool/gpu.yaml", {
            "addon": "capacity-pool-gpu",
            "values": {"pool": {"name": "gpu", "startupTaints": [{"key": "distai.dev/startup-not-ready", "effect": "NoExecute"}]}},
        }),
        "matches vigil-controller's taintEffect",
    )
    case(
        "a DRA-method pool with pool.startupTaints fails only the DRA-combination rule",
        lambda root: _write(root, "gitops/cells/good-cell/capacity-pool/gpu.yaml", {
            "addon": "capacity-pool-gpu",
            "values": {
                "pool": {"name": "gpu", "startupTaints": [{"key": "distai.dev/startup-not-ready", "effect": "NoSchedule"}]},
                "accelerator": {"methodLabel": {"key": "distai.dev/nvidia-gpu-method", "value": "dra"}},
            },
        }),
        "does not combine accelerator.methodLabel value 'dra' with pool.startupTaints",
    )
    case(
        "vigil-controller's own taintKey missing from its knownStartupTaintKeys fails that one rule",
        lambda root: _write(root, "gitops/addons/vigil-controller/addon.yaml", {
            "addon": "vigil-controller",
            "values": {"config": {
                "taintKey": "distai.dev/startup-not-ready",
                "taintEffect": "NoSchedule",
                "knownStartupTaintKeys": ["distai.dev/some-other-key"],
            }},
        }),
        "knownStartupTaintKeys",
    )
    case(
        "a device-plugin add-on that stopped tolerating the key fails only that add-on's rule",
        lambda root: _write(root, "gitops/addons/accel-nvidia-device-plugin/addon.yaml", {
            "addon": "accel-nvidia-device-plugin",
            "values": {"tolerations": [{"key": "CriticalAddonsOnly", "operator": "Exists"}]},
        }),
        "accel-nvidia-device-plugin/addon.yaml's values.tolerations tolerates",
    )

    failures = 0
    for name, mutate, expect_substr in cases:
        tmp = tempfile.mkdtemp(prefix="check-startup-taint-keys-selftest-")
        try:
            _baseline(tmp)
            mutate(tmp)
            rc, fails = _run(tmp)
            if expect_substr is None:
                ok = rc == 0 and not fails
                detail = f"expected a clean pass, got rc={rc} failures={fails}"
            else:
                ok = rc != 0 and len(fails) == 1 and expect_substr in fails[0]
                detail = f"expected exactly one failure, the {expect_substr!r} rule, got {fails}"
            check(f"selftest: {name}", ok, detail)
            if not ok:
                failures += 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        print("usage: check_startup_taint_keys.py <repo_root> | check_startup_taint_keys.py --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
