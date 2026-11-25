#!/usr/bin/env python3
"""Render a capacity-pool `pool.networkInterfaces` value from DescribeInstanceTypes.

Which network cards of an instance type carry EFA, which `deviceIndex` the EFA
interface uses, and how many cards there are differ per instance family and are
not derivable from the instance type name. Writing the resulting 17- or
33-entry list by hand is not reviewable in a diff, so this script derives it
from the `NetworkInfo` block of one `aws ec2 describe-instance-types` response
(issue #50). It never calls AWS: the response is captured once, by hand, when
an instance type is onboarded (see README.md next to this file), and committed
as a fixture.

With C = NetworkInfo.MaximumNetworkCards and
E = NetworkInfo.EfaInfo.MaximumEfaInterfaces:

- E == C (every card carries EFA; this includes the single-card case C == 1):
  card 0 gets the primary `interface` at deviceIndex 0 plus `efa-only` at
  deviceIndex 1, and every other card gets `efa-only` at deviceIndex 1.
- E == C - 1 (one card carries no EFA): the API does not say which card is
  excluded or which deviceIndex the other cards use, so both facts come from an
  entry for the instance family in exceptions.json. The excluded card gets only
  the primary `interface`; every other card gets `efa-only` at the entry's
  `secondaryDeviceIndex`. A family with no entry is refused, not guessed.
- Anything else, including an instance type without EFA, is refused.

Karpenter's EC2NodeClass requires the primary `interface` entry on
networkCardIndex 0, deviceIndex 0, and accepts only `interface` and `efa-only`
as interfaceType, which is why card 0 is always split into two entries.

The E == C path is NOT gated by an exceptions.json-style per-family allowlist:
it renders for any instance type whose own C and E happen to match, including
one this platform has not independently confirmed the deviceIndex convention
for (trn2.48xlarge is exactly this case -- see tools/README.md's Known
issues). Only E == C - 1 is refused for an unlisted family, because the API
gives no signal at all for that shape (see the module docstring's case 2
above); E == C needs no such table because every family this generator has
onboarded so far agrees on deviceIndex 1, but that is an empirical pattern
across the onboarded set, not something this script derives or enforces. The
actual safeguard for an unconfirmed E == C family is that nobody commits a
fixture for it until a named source or a real node confirms it -- a review
discipline, not a check this script performs.

If the describe JSON carries an optional `_source.instanceType` field (this
platform's own fixtures do, recording where the capture came from), it is
cross-checked against --instance-type and a mismatch is refused: this stops
an exceptions.json entry meant for one family from being applied to a
different --describe-json/--instance-type pairing by mistake. The field is
optional and ignored for a describe JSON that lacks it.

Output goes to stdout as a YAML list, byte-for-byte deterministic for the same
inputs; errors go to stderr with a non-zero exit and nothing on stdout.
"""

import argparse
import json
import sys


class Refused(Exception):
    """The inputs do not determine a layout this script is willing to emit."""


def layout(network_info, instance_type, exceptions):
    """Return (header comment lines, [(networkCardIndex, deviceIndex, interfaceType)])."""
    if not isinstance(network_info, dict):
        raise Refused(f"{instance_type}: the describe JSON must be the NetworkInfo object itself")
    source = network_info.get("_source")
    if isinstance(source, dict) and "instanceType" in source and source["instanceType"] != instance_type:
        raise Refused(f"{instance_type}: --describe-json was captured for instance type "
                      f"{source['instanceType']!r} (its own _source.instanceType), not {instance_type!r}; "
                      "pass the fixture captured for this instance type, not a borrowed one")
    cards = network_info.get("MaximumNetworkCards")
    efa_info = network_info.get("EfaInfo")
    efa = efa_info.get("MaximumEfaInterfaces", 0) if isinstance(efa_info, dict) else 0
    if type(cards) is not int or cards < 1:
        raise Refused(f"{instance_type}: NetworkInfo.MaximumNetworkCards is missing or not a positive integer")
    if network_info.get("EfaSupported") is not True or type(efa) is not int or efa < 1:
        raise Refused(f"{instance_type}: EFA is not supported (EfaSupported is false or "
                      "EfaInfo.MaximumEfaInterfaces is absent/0); leave pool.networkInterfaces empty")

    if efa == cards:
        entries = [(0, 0, "interface"), (0, 1, "efa-only")]
        entries += [(i, 1, "efa-only") for i in range(1, cards)]
        return ["every network card carries EFA (E == C)."], entries

    if efa == cards - 1:
        family = instance_type.split(".", 1)[0]
        entry = exceptions.get(family) if isinstance(exceptions, dict) else None
        if not isinstance(entry, dict):
            raise Refused(f"{instance_type}: {efa} EFA interfaces on {cards} network cards (E == C - 1), and "
                          f"exceptions.json has no entry for family {family!r}; DescribeInstanceTypes does not "
                          "say which card lacks EFA or which deviceIndex the others use, so add an entry "
                          "from a named source instead of guessing")
        excluded = entry.get("excludedCard")
        secondary = entry.get("secondaryDeviceIndex")
        if type(excluded) is not int or excluded != 0:
            raise Refused(f"exceptions.json[{family!r}].excludedCard is {excluded!r}; only 0 is supported. "
                          "This code always puts the primary interface on the excluded card, which Karpenter "
                          "only accepts on networkCardIndex 0 -- that is correct for p6-b300, where card 0 "
                          "happens to be both the excluded one and the primary one, but would need different "
                          "code (not just a different value here) for a family where those two were not the "
                          "same card, so this refuses rather than emitting a layout Karpenter would reject")
        if type(secondary) is not int or secondary < 0:
            raise Refused(f"exceptions.json[{family!r}].secondaryDeviceIndex must be a non-negative integer")
        entries = [(excluded, 0, "interface")]
        entries += [(i, secondary, "efa-only") for i in range(cards) if i != excluded]
        confirmed = "confirmed" if entry.get("confirmed") is True else "not confirmed"
        return [f"card {excluded} carries no EFA (E == C - 1); exceptions.json entry {family!r},",
                f"{confirmed} on real hardware by this platform (see the entry's source)."], entries

    raise Refused(f"{instance_type}: {efa} EFA interfaces on {cards} network cards is neither E == C nor "
                  "E == C - 1; no layout rule covers it")


def render(instance_type, notes, entries):
    lines = [f"# {instance_type}: {notes[0]}"] + [f"# {note}" for note in notes[1:]]
    lines.append("# Generated by render-network-interfaces.py; do not edit by hand.")
    for card, device, kind in entries:
        lines += [f"- networkCardIndex: {card}", f"  deviceIndex: {device}", f"  interfaceType: {kind}"]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--describe-json", required=True,
                        help="file holding InstanceTypes[0].NetworkInfo of a describe-instance-types response")
    parser.add_argument("--instance-type", required=True, help="for example p5en.48xlarge")
    parser.add_argument("--exceptions", required=True, help="path to exceptions.json")
    args = parser.parse_args(argv)
    try:
        with open(args.describe_json, encoding="utf-8") as f:
            network_info = json.load(f)
        with open(args.exceptions, encoding="utf-8") as f:
            exceptions = json.load(f)
        notes, entries = layout(network_info, args.instance_type, exceptions)
    except (OSError, ValueError, Refused) as err:
        print(f"render-network-interfaces: error: {err}", file=sys.stderr)
        return 1
    sys.stdout.write(render(args.instance_type, notes, entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
