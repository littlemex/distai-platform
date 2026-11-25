#!/usr/bin/env python3
"""Check the pool.networkInterfaces generator of gitops/charts/capacity-pool
(issue #50) against committed data only: no AWS credentials, no network.

The generator, gitops/charts/capacity-pool/tools/render-network-interfaces.py,
is called as an external program with the contract issue #50's design
decision pins:

    render-network-interfaces.py --describe-json <path> \
        --instance-type <name> --exceptions <path to exceptions.json>

It prints the pool.networkInterfaces YAML fragment on stdout, or exits
non-zero with nothing on stdout when it refuses. This script never imports
it and never copies its logic; the expected layouts below are derived
separately from issue #50's own algorithm and its per-instance-type table,
so that a generator bug and a fixture regenerated to match that bug are
both caught.

Checks, each printing one PASS or FAIL line:

  1. fixture pairs: every <type>.describe.json under tools/fixtures/ has a
     <type>.networkInterfaces.yaml and the reverse, and every instance type
     in GROUND_TRUTH below has a pair.
  2. drift: for every pair, the generator's stdout for that describe.json
     and the committed exceptions.json is byte-identical to the committed
     .networkInterfaces.yaml (nothing is stripped or normalized: the fixture
     is defined as the generator's own stdout).
  3. layout: for every pair, the committed describe.json's
     MaximumNetworkCards (C) and EfaInfo.MaximumEfaInterfaces (E) equal
     GROUND_TRUTH, and the committed .networkInterfaces.yaml is exactly the
     list issue #50's algorithm gives for (C, E): entry count, card 0's
     entries (interface + efa-only, or interface only for the p6-b300
     exception), the secondary cards' deviceIndex (1, or 0 for p6-b300),
     every value an integer or one of Karpenter's two interfaceType names.
  4. refusals: on synthetic NetworkInfo inputs built from a committed
     describe.json (same document shape, only C/E/EfaSupported changed), the
     generator exits non-zero with empty stdout for EFA unsupported,
     E == C - 1 for a family with no exceptions.json entry, and E neither C
     nor C - 1; and, as positive controls proving the synthetic shape is
     accepted at all, it prints the expected layout for E == C, C == 1, and
     E == C - 1 under the p6-b300 family name.
  5. exceptions.json: exactly one p6-b300 entry, its `confirmed` is the JSON
     boolean false, and its `source` is a non-empty string naming
     awsome-distributed-ai.

Usage: check_nic_layout.py <repo_root> | check_nic_layout.py --selftest
"""
from __future__ import annotations

import copy
import difflib
import glob
import json
import os
import subprocess
import sys
import tempfile

import yaml

FAILURES: list[str] = []

TOOLS_REL = os.path.join("gitops", "charts", "capacity-pool", "tools")
GENERATOR_NAME = "render-network-interfaces.py"
EXCEPTIONS_NAME = "exceptions.json"
DESCRIBE_SUFFIX = ".describe.json"
LAYOUT_SUFFIX = ".networkInterfaces.yaml"

# (MaximumNetworkCards, EfaInfo.MaximumEfaInterfaces) per instance type, as
# returned by read-only `aws ec2 describe-instance-types` and listed in
# issue #50's "Confirmed per-instance-type layout" table. A committed
# describe.json that disagrees with this table fails check 3: the fixture
# changed, not only the generator.
GROUND_TRUTH: dict[str, tuple[int, int]] = {
    "p5.48xlarge": (32, 32),
    "p5e.48xlarge": (32, 32),
    "p5en.48xlarge": (16, 16),
    "p4d.24xlarge": (4, 4),
    "p6-b200.48xlarge": (8, 8),
    "p6-b300.48xlarge": (17, 16),
    "g6e.48xlarge": (4, 4),
    "g6e.12xlarge": (1, 1),
    "g7.48xlarge": (2, 2),
}

# Issue #50 case 4 (E == C - 1): the facts DescribeInstanceTypes does not
# return, per instance family, from the sources the issue cites. Card 0 is
# the excluded one and carries only the primary interface; cards 1..C-1
# carry efa-only at this deviceIndex.
CASE4_SECONDARY_DEVICE_INDEX: dict[str, int] = {
    "p6-b300": 0,
}

# Case 3 (E == C, including the single-card case C == 1): card 0 carries the
# primary interface at deviceIndex 0 and its own efa-only at deviceIndex 1;
# cards 1..C-1 carry efa-only at deviceIndex 1.
CASE3_SECONDARY_DEVICE_INDEX = 1

SYNTHETIC_UNKNOWN_TYPE = "zz9.99xlarge"
SYNTHETIC_CASE4_TYPE = "p6-b300.48xlarge"
GENERATOR_TIMEOUT_SECONDS = 60

Entry = tuple[int, int, str]


def check(label: str, condition: bool, reason: str = "") -> bool:
    if condition:
        print(f"PASS {label}")
    else:
        msg = f"FAIL {label}" + (f": {reason}" if reason else "")
        print(msg)
        FAILURES.append(msg)
    return condition


def family_of(instance_type: str) -> str:
    return instance_type.split(".", 1)[0]


def expected_layout(instance_type: str, cards: int, efa: int) -> list[Entry] | None:
    """Issue #50's algorithm, written out independently. None = must refuse."""
    if not isinstance(cards, int) or not isinstance(efa, int) or cards < 1 or efa < 1:
        return None
    if efa == cards:
        layout = [(0, 0, "interface"), (0, 1, "efa-only")]
        layout += [(i, CASE3_SECONDARY_DEVICE_INDEX, "efa-only") for i in range(1, cards)]
        return layout
    if efa == cards - 1 and family_of(instance_type) in CASE4_SECONDARY_DEVICE_INDEX:
        dev = CASE4_SECONDARY_DEVICE_INDEX[family_of(instance_type)]
        return [(0, 0, "interface")] + [(i, dev, "efa-only") for i in range(1, cards)]
    return None


def find_network_info(doc) -> dict | None:
    """The NetworkInfo mapping inside a trimmed describe.json: the document
    itself, or under NetworkInfo, or under InstanceTypes[0].NetworkInfo."""
    if isinstance(doc, dict):
        if "MaximumNetworkCards" in doc:
            return doc
        if isinstance(doc.get("NetworkInfo"), dict):
            return find_network_info(doc["NetworkInfo"])
        its = doc.get("InstanceTypes")
        if isinstance(its, list) and len(its) == 1:
            return find_network_info(its[0])
    return None


def cards_and_efa(network_info: dict) -> tuple[object, object]:
    efa_info = network_info.get("EfaInfo") or {}
    return network_info.get("MaximumNetworkCards"), efa_info.get("MaximumEfaInterfaces")


def parse_layout(text: str) -> tuple[list[Entry] | None, str]:
    """(entries, "") or (None, reason). Accepts a bare list, or the list under
    networkInterfaces:, or under pool.networkInterfaces: -- the three ways a
    `pool.networkInterfaces` fragment can be written. Each entry must have
    exactly networkCardIndex/deviceIndex (integers) and interfaceType (one of
    Karpenter's two enum values)."""
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as e:
        return None, f"not valid YAML: {e}"
    if isinstance(doc, dict) and set(doc) == {"pool"} and isinstance(doc["pool"], dict):
        doc = doc["pool"]
    if isinstance(doc, dict) and set(doc) == {"networkInterfaces"}:
        doc = doc["networkInterfaces"]
    if not isinstance(doc, list) or not doc:
        return None, f"not a non-empty list (got {type(doc).__name__})"
    out: list[Entry] = []
    for n, item in enumerate(doc):
        if not isinstance(item, dict) or set(item) != {"networkCardIndex", "deviceIndex", "interfaceType"}:
            return None, f"entry {n} must have exactly networkCardIndex, deviceIndex, interfaceType; got {item!r}"
        card, dev, kind = item["networkCardIndex"], item["deviceIndex"], item["interfaceType"]
        for name, v in (("networkCardIndex", card), ("deviceIndex", dev)):
            if not isinstance(v, int) or isinstance(v, bool):
                return None, f"entry {n} {name} must be a YAML integer, got {v!r}"
        if kind not in ("interface", "efa-only"):
            return None, f"entry {n} interfaceType must be interface or efa-only, got {kind!r}"
        out.append((card, dev, kind))
    return out, ""


def layout_facts(layout: list[Entry]) -> dict:
    return {
        "entries": len(layout),
        "card0": [kind for card, _, kind in layout if card == 0],
        "secondary deviceIndex": sorted({dev for card, dev, _ in layout if card != 0}),
        "efa-only on card 0": any(card == 0 and kind == "efa-only" for card, _, kind in layout),
    }


def compare_layout(expected: list[Entry], got: list[Entry]) -> str:
    """"" when equal, otherwise the differing facts as expected vs. got."""
    if expected == got:
        return ""
    ef, gf = layout_facts(expected), layout_facts(got)
    diffs = [f"{k} expected {ef[k]} got {gf[k]}" for k in ef if ef[k] != gf[k]]
    if not diffs:
        i = next(i for i in range(max(len(expected), len(got))) if i >= len(expected) or i >= len(got) or expected[i] != got[i])
        diffs = [f"entry {i} expected {expected[i] if i < len(expected) else None} got {got[i] if i < len(got) else None}"]
    return "; ".join(diffs)


def run_generator(generator: str, describe: str, instance_type: str, exceptions: str, cwd: str) -> tuple[int, bytes, bytes]:
    try:
        proc = subprocess.run(
            [sys.executable, generator, "--describe-json", describe, "--instance-type", instance_type, "--exceptions", exceptions],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=GENERATOR_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return -1, b"", b"timed out"
    return proc.returncode, proc.stdout, proc.stderr


def fixture_pairs(fixtures_dir: str) -> tuple[list[str], list[str]]:
    """(instance types with a full pair, orphan file names)."""
    describes = {os.path.basename(p)[: -len(DESCRIBE_SUFFIX)] for p in glob.glob(os.path.join(fixtures_dir, "*" + DESCRIBE_SUFFIX))}
    layouts = {os.path.basename(p)[: -len(LAYOUT_SUFFIX)] for p in glob.glob(os.path.join(fixtures_dir, "*" + LAYOUT_SUFFIX))}
    orphans = [t + DESCRIBE_SUFFIX for t in sorted(describes - layouts)] + [t + LAYOUT_SUFFIX for t in sorted(layouts - describes)]
    return sorted(describes & layouts), orphans


def check_pairs(fixtures_dir: str) -> list[str]:
    pairs, orphans = fixture_pairs(fixtures_dir)
    check("nic-layout fixtures: every describe.json has a networkInterfaces.yaml and the reverse", not orphans, f"orphans: {orphans}")
    missing = sorted(set(GROUND_TRUTH) - set(pairs))
    check(f"nic-layout fixtures: all {len(GROUND_TRUTH)} issue #50 instance types have a fixture pair", not missing, f"missing: {missing}")
    return pairs


def check_drift(generator: str, fixtures_dir: str, exceptions: str, cwd: str, pairs: list[str]) -> None:
    for t in pairs:
        describe = os.path.join(fixtures_dir, t + DESCRIBE_SUFFIX)
        with open(os.path.join(fixtures_dir, t + LAYOUT_SUFFIX), "rb") as f:
            committed = f.read()
        rc, out, err = run_generator(generator, describe, t, exceptions, cwd)
        label = f"nic-layout drift: {t} generator output == committed {t}{LAYOUT_SUFFIX}"
        if rc != 0:
            check(label, False, f"generator exited {rc}: {err.decode(errors='replace').strip()[-400:]}")
            continue
        if out == committed:
            check(label, True)
            continue
        diff = difflib.unified_diff(
            committed.decode(errors="replace").splitlines(keepends=True),
            out.decode(errors="replace").splitlines(keepends=True),
            "committed",
            "generated",
        )
        check(label, False, "byte difference:\n" + "".join(list(diff)[:40]))


def check_layouts(fixtures_dir: str, pairs: list[str]) -> None:
    for t in pairs:
        label = f"nic-layout layout: {t}"
        with open(os.path.join(fixtures_dir, t + DESCRIBE_SUFFIX), encoding="utf-8") as f:
            try:
                ni = find_network_info(json.load(f))
            except json.JSONDecodeError as e:
                check(label, False, f"{t}{DESCRIBE_SUFFIX} is not valid JSON: {e}")
                continue
        if ni is None:
            check(label, False, f"{t}{DESCRIBE_SUFFIX} has no NetworkInfo with MaximumNetworkCards")
            continue
        cards, efa = cards_and_efa(ni)
        if t in GROUND_TRUTH and (cards, efa) != GROUND_TRUTH[t]:
            check(label, False, f"describe.json (MaximumNetworkCards, MaximumEfaInterfaces) expected {GROUND_TRUTH[t]} got {(cards, efa)}")
            continue
        expected = expected_layout(t, cards, efa)
        if expected is None:
            check(label, False, f"(C, E) = {(cards, efa)} is a shape issue #50 says must be refused, yet a fixture is committed for it")
            continue
        with open(os.path.join(fixtures_dir, t + LAYOUT_SUFFIX), encoding="utf-8") as f:
            got, reason = parse_layout(f.read())
        if got is None:
            check(label, False, f"{t}{LAYOUT_SUFFIX}: {reason}")
            continue
        diff = compare_layout(expected, got)
        ef = layout_facts(expected)
        check(label + f" ({ef['entries']} entries, card 0 {ef['card0']}, secondary deviceIndex {ef['secondary deviceIndex']})", not diff, diff)


def synthetic(base_doc, cards: int, efa: int | None, efa_supported: bool) -> object:
    """A copy of base_doc with only C, E and EfaSupported changed (E None =
    no EfaInfo at all), and NetworkCards resized to match C."""
    doc = copy.deepcopy(base_doc)
    ni = find_network_info(doc)
    ni["MaximumNetworkCards"] = cards
    ni["EfaSupported"] = efa_supported
    if efa is None:
        ni.pop("EfaInfo", None)
    else:
        ni["EfaInfo"] = dict(ni.get("EfaInfo") or {}, MaximumEfaInterfaces=efa)
    template = (ni.get("NetworkCards") or [{}])[0]
    if "NetworkCards" in ni:
        ni["NetworkCards"] = [dict(copy.deepcopy(template), NetworkCardIndex=i) for i in range(cards)]
    return doc


def check_refusals(generator: str, fixtures_dir: str, exceptions: str, cwd: str, pairs: list[str]) -> None:
    base_type = "p5en.48xlarge" if "p5en.48xlarge" in pairs else (pairs[0] if pairs else None)
    if base_type is None:
        check("nic-layout refusals: a committed describe.json to build synthetic inputs from", False, "no fixture pair found")
        return
    with open(os.path.join(fixtures_dir, base_type + DESCRIBE_SUFFIX), encoding="utf-8") as f:
        base_doc = json.load(f)
    if find_network_info(base_doc) is None:
        check("nic-layout refusals: a committed describe.json to build synthetic inputs from", False, f"{base_type}{DESCRIBE_SUFFIX} has no NetworkInfo")
        return

    # (label, instance type, C, E, EfaSupported, must refuse)
    cases = [
        ("EFA unsupported (no EfaInfo, EfaSupported false)", SYNTHETIC_UNKNOWN_TYPE, 4, None, False, True),
        ("EFA unsupported (MaximumEfaInterfaces 0, EfaSupported false)", SYNTHETIC_UNKNOWN_TYPE, 4, 0, False, True),
        ("MaximumEfaInterfaces 0 with EfaSupported true", SYNTHETIC_UNKNOWN_TYPE, 4, 0, True, True),
        (f"E == C - 1 (C=5, E=4) for {SYNTHETIC_UNKNOWN_TYPE}, family absent from exceptions.json", SYNTHETIC_UNKNOWN_TYPE, 5, 4, True, True),
        ("E == C - 1 (C=5, E=4) for p5.48xlarge, an E == C family absent from exceptions.json", "p5.48xlarge", 5, 4, True, True),
        (f"E neither C nor C - 1 (C=5, E=3) for {SYNTHETIC_UNKNOWN_TYPE}", SYNTHETIC_UNKNOWN_TYPE, 5, 3, True, True),
        (f"E neither C nor C - 1 (C=5, E=3) for {SYNTHETIC_CASE4_TYPE}, a family that has an exception entry", SYNTHETIC_CASE4_TYPE, 5, 3, True, True),
        (f"E greater than C (C=4, E=5) for {SYNTHETIC_UNKNOWN_TYPE}", SYNTHETIC_UNKNOWN_TYPE, 4, 5, True, True),
        (f"positive control: E == C (C=5, E=5) for {SYNTHETIC_UNKNOWN_TYPE}", SYNTHETIC_UNKNOWN_TYPE, 5, 5, True, False),
        (f"positive control: single card (C=1, E=1) for {SYNTHETIC_UNKNOWN_TYPE}", SYNTHETIC_UNKNOWN_TYPE, 1, 1, True, False),
        (f"positive control: E == C - 1 (C=5, E=4) for {SYNTHETIC_CASE4_TYPE}", SYNTHETIC_CASE4_TYPE, 5, 4, True, False),
    ]
    tmp = tempfile.mkdtemp(prefix="check-nic-layout-")
    try:
        for n, (desc, itype, cards, efa, supported, must_refuse) in enumerate(cases):
            path = os.path.join(tmp, f"case{n}{DESCRIBE_SUFFIX}")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(synthetic(base_doc, cards, efa, supported), f, indent=2)
            rc, out, err = run_generator(generator, path, itype, exceptions, cwd)
            if must_refuse:
                check(
                    f"nic-layout refusal: {desc}",
                    rc != 0 and out == b"",
                    f"expected non-zero exit and empty stdout, got exit {rc}, stdout {out.decode(errors='replace')[:200]!r}",
                )
                continue
            expected = expected_layout(itype, cards, efa)
            if rc != 0:
                check(f"nic-layout {desc}", False, f"generator exited {rc}: {err.decode(errors='replace').strip()[-400:]}")
                continue
            got, reason = parse_layout(out.decode(errors="replace"))
            if got is None:
                check(f"nic-layout {desc}", False, reason)
                continue
            diff = compare_layout(expected, got)
            check(f"nic-layout {desc}", not diff, diff)
    finally:
        import shutil

        shutil.rmtree(tmp, ignore_errors=True)


def check_exceptions(path: str) -> None:
    label = "nic-layout exceptions.json"
    dup_keys: list[str] = []

    def pairs_hook(items):
        seen = set()
        for k, _ in items:
            if k in seen:
                dup_keys.append(k)
            seen.add(k)
        return dict(items)

    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f, object_pairs_hook=pairs_hook)
    except FileNotFoundError:
        check(label + " exists", False, f"{path} not found")
        return
    except json.JSONDecodeError as e:
        check(label + " is valid JSON", False, str(e))
        return
    check(label + ": no duplicate keys", not dup_keys, f"duplicate keys: {sorted(set(dup_keys))}")
    if not isinstance(doc, dict):
        check(label + ": top level is an object keyed by instance family", False, f"got {type(doc).__name__}")
        return
    entry = doc.get("p6-b300")
    if not check(label + ": has a p6-b300 entry (an object)", isinstance(entry, dict), f"got {entry!r}"):
        return
    check(
        label + ": p6-b300 confirmed is the JSON boolean false (table-only, issue #50)",
        "confirmed" in entry and entry["confirmed"] is False,
        f"got {entry.get('confirmed', '<missing>')!r}",
    )
    source = entry.get("source")
    check(
        label + ": p6-b300 source is a non-empty string naming awsome-distributed-ai",
        isinstance(source, str) and source.strip() != "" and "awsome-distributed-ai" in source,
        f"got {source!r}",
    )


def main(root: str) -> int:
    tools = os.path.join(root, TOOLS_REL)
    generator = os.path.join(tools, GENERATOR_NAME)
    fixtures_dir = os.path.join(tools, "fixtures")
    exceptions = os.path.join(tools, EXCEPTIONS_NAME)
    if not check(f"nic-layout generator exists ({os.path.join(TOOLS_REL, GENERATOR_NAME)})", os.path.isfile(generator)):
        return 1
    pairs = check_pairs(fixtures_dir)
    check_exceptions(exceptions)
    check_drift(generator, fixtures_dir, exceptions, root, pairs)
    check_layouts(fixtures_dir, pairs)
    check_refusals(generator, fixtures_dir, exceptions, root, pairs)
    if FAILURES:
        print(f"\nRESULT FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("\nRESULT PASS: all nic-layout checks passed")
    return 0


# ------------------------------------------------------------- selftest
#
# A checker only ever seen green is not evidence it fails on what it claims
# to catch. Each case below builds a throwaway repo root with correct
# fixtures and a stub generator (never the committed one), mutates one
# thing, and asserts exactly which checks fail. The cases include the
# defect issue #50 exists to prevent, p5en.48xlarge's secondary cards at
# deviceIndex 0, both in the fixture alone and in generator and fixture
# alike (the case the drift check alone cannot see).


def _layout_yaml(entries: list[Entry]) -> str:
    return "".join(f"- networkCardIndex: {c}\n  deviceIndex: {d}\n  interfaceType: {k}\n" for c, d, k in entries)


def _describe(cards: int, efa: int) -> dict:
    return {
        "MaximumNetworkCards": cards,
        "EfaSupported": True,
        "EfaInfo": {"MaximumEfaInterfaces": efa},
        "NetworkCards": [{"NetworkCardIndex": i} for i in range(cards)],
    }


GOOD_EXCEPTIONS = {"p6-b300": {"confirmed": False, "source": "awslabs/awsome-distributed-ai NicLayout"}}


def _baseline(root: str, stub: str) -> str:
    tools = os.path.join(root, TOOLS_REL)
    fixtures = os.path.join(tools, "fixtures")
    os.makedirs(fixtures)
    for t, (c, e) in GROUND_TRUTH.items():
        with open(os.path.join(fixtures, t + DESCRIBE_SUFFIX), "w", encoding="utf-8") as f:
            json.dump(_describe(c, e), f)
        with open(os.path.join(fixtures, t + LAYOUT_SUFFIX), "w", encoding="utf-8") as f:
            f.write(_layout_yaml(expected_layout(t, c, e)))
    with open(os.path.join(tools, EXCEPTIONS_NAME), "w", encoding="utf-8") as f:
        json.dump(GOOD_EXCEPTIONS, f)
    with open(os.path.join(tools, GENERATOR_NAME), "w", encoding="utf-8") as f:
        f.write(stub)
    return fixtures


# A stub generator built on this script's own expected_layout(): a correct
# generator by construction, so the baseline passes every check with zero
# failures and each mutation below must fail exactly the checks it names.
STUB_ORACLE = """import json, sys
sys.path.insert(0, {tests_dir!r})
import check_nic_layout as c
a = dict(zip(sys.argv[1::2], sys.argv[2::2]))
ni = c.find_network_info(json.load(open(a["--describe-json"])))
layout = c.expected_layout(a["--instance-type"], *c.cards_and_efa(ni)) if ni else None
if layout is None:
    sys.exit(1)
sys.stdout.write(c._layout_yaml(layout){suffix})
"""


def _oracle(suffix: str = "") -> str:
    return STUB_ORACLE.format(tests_dir=os.path.dirname(os.path.abspath(__file__)), suffix=suffix)


# Prints a layout for every input: every refusal case must fail.
STUB_ALWAYS = "import sys\nsys.stdout.write('- networkCardIndex: 0\\n  deviceIndex: 0\\n  interfaceType: interface\\n')\n"


def _run(root: str) -> tuple[int, list[str]]:
    global FAILURES
    FAILURES = []
    import contextlib
    import io

    with contextlib.redirect_stdout(io.StringIO()):
        rc = main(root)
    return rc, list(FAILURES)


def selftest() -> int:
    import shutil

    p5en = "p5en.48xlarge"
    b300 = "p6-b300.48xlarge"

    def write(fixtures: str, name: str, text: str) -> None:
        with open(os.path.join(fixtures, name), "w", encoding="utf-8") as f:
            f.write(text)

    def write_exc(root: str, doc_text: str) -> None:
        write(os.path.join(root, TOOLS_REL), EXCEPTIONS_NAME, doc_text)

    p5en_dev0 = [(0, 0, "interface"), (0, 1, "efa-only")] + [(i, 0, "efa-only") for i in range(1, 16)]
    b300_card0_efa = [(0, 0, "interface"), (0, 1, "efa-only")] + [(i, 0, "efa-only") for i in range(1, 17)]
    b300_dev1 = [(0, 0, "interface")] + [(i, 1, "efa-only") for i in range(1, 17)]

    # (name, stub, mutate(root, fixtures), substrings): the run must fail,
    # every failure must contain one of the substrings, and every substring
    # must appear in at least one failure. An empty list = a clean pass.
    cases = [
        ("baseline: correct generator and fixtures pass everything", _oracle(), lambda r, fx: None, []),
        (
            "p5en secondary deviceIndex 0 in the fixture (the defect issue #50 exists to prevent)",
            _oracle(),
            lambda r, fx: write(fx, p5en + LAYOUT_SUFFIX, _layout_yaml(p5en_dev0)),
            [f"layout: {p5en}", f"drift: {p5en}"],
        ),
        (
            "p5en secondary deviceIndex 0 in generator and fixture alike",
            _oracle().replace("sys.stdout.write(", "layout = [(x, 0 if x else d, k) for x, d, k in layout]\nsys.stdout.write("),
            lambda r, fx: write(fx, p5en + LAYOUT_SUFFIX, _layout_yaml(p5en_dev0)),
            [f"layout: {p5en}", "drift:", "positive control"],
        ),
        ("p6-b300 with efa-only on card 0", _oracle(), lambda r, fx: write(fx, b300 + LAYOUT_SUFFIX, _layout_yaml(b300_card0_efa)), [f"layout: {b300}", f"drift: {b300}"]),
        ("p6-b300 secondary deviceIndex 1", _oracle(), lambda r, fx: write(fx, b300 + LAYOUT_SUFFIX, _layout_yaml(b300_dev1)), [f"layout: {b300}", f"drift: {b300}"]),
        (
            "p5en deviceIndex written as a quoted string",
            _oracle(),
            lambda r, fx: write(fx, p5en + LAYOUT_SUFFIX, _layout_yaml(expected_layout(p5en, 16, 16)).replace("deviceIndex: 1", 'deviceIndex: "1"')),
            [f"layout: {p5en}", f"drift: {p5en}"],
        ),
        ("p5en describe.json drifted to 15 cards", _oracle(), lambda r, fx: write(fx, p5en + DESCRIBE_SUFFIX, json.dumps(_describe(15, 15))), [f"layout: {p5en}", f"drift: {p5en}"]),
        (
            "missing g7.48xlarge pair",
            _oracle(),
            lambda r, fx: (os.remove(os.path.join(fx, "g7.48xlarge" + DESCRIBE_SUFFIX)), os.remove(os.path.join(fx, "g7.48xlarge" + LAYOUT_SUFFIX))),
            ["have a fixture pair"],
        ),
        ("orphan describe.json", _oracle(), lambda r, fx: write(fx, "x1.large" + DESCRIBE_SUFFIX, json.dumps(_describe(2, 2))), ["and the reverse"]),
        ("exceptions confirmed true", _oracle(), lambda r, fx: write_exc(r, json.dumps({"p6-b300": {"confirmed": True, "source": "awsome-distributed-ai"}})), ["confirmed is"]),
        ("exceptions confirmed as the string false", _oracle(), lambda r, fx: write_exc(r, json.dumps({"p6-b300": {"confirmed": "false", "source": "awsome-distributed-ai"}})), ["confirmed is"]),
        ("exceptions source missing", _oracle(), lambda r, fx: write_exc(r, json.dumps({"p6-b300": {"confirmed": False}})), ["source is"]),
        ("exceptions source not naming awsome-distributed-ai", _oracle(), lambda r, fx: write_exc(r, json.dumps({"p6-b300": {"confirmed": False, "source": "internal notes"}})), ["source is"]),
        (
            "exceptions duplicate p6-b300 key",
            _oracle(),
            lambda r, fx: write_exc(r, '{"p6-b300": {"confirmed": false, "source": "awsome-distributed-ai"}, "p6-b300": {"confirmed": false, "source": "awsome-distributed-ai"}}'),
            ["duplicate keys"],
        ),
        ("exceptions without p6-b300", _oracle(), lambda r, fx: write_exc(r, "{}"), ["has a p6-b300 entry"]),
        ("generator output one trailing newline longer than the fixture", _oracle(" + '\\n'"), lambda r, fx: None, ["drift:"]),
        ("generator that never refuses", STUB_ALWAYS, lambda r, fx: None, ["refusal:", "drift:", "positive control"]),
    ]

    failures = 0
    for name, stub, mutate, expect in cases:
        tmp = tempfile.mkdtemp(prefix="check-nic-layout-selftest-")
        try:
            fixtures = _baseline(tmp, stub)
            mutate(tmp, fixtures)
            rc, fails = _run(tmp)
            unexplained = [f for f in fails if not any(s in f for s in expect)]
            unmatched = [s for s in expect if not any(s in f for f in fails)]
            ok = (rc == 0 and not fails) if not expect else (rc != 0 and not unexplained and not unmatched)
            check(f"selftest: {name}", ok, f"unexpected failures {unexplained}; expected but absent {unmatched}")
            if not ok:
                failures += 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # Pure-function cases, independent of any stub.
    expected_shapes = {
        ("p5en.48xlarge", 16, 16): 17,
        ("p6-b300.48xlarge", 17, 16): 17,
        ("g6e.12xlarge", 1, 1): 2,
        ("zz9.99xlarge", 5, 4): None,
        ("zz9.99xlarge", 5, 3): None,
        ("zz9.99xlarge", 4, 0): None,
    }
    for (t, c, e), n in expected_shapes.items():
        got = expected_layout(t, c, e)
        ok = (got is None) if n is None else (got is not None and len(got) == n)
        check(f"selftest: expected_layout({t}, C={c}, E={e}) -> {n if n is not None else 'refuse'}", ok, f"got {got}")
        failures += 0 if ok else 1
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) != 2:
        print("usage: check_nic_layout.py <repo-root> | check_nic_layout.py --selftest", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
