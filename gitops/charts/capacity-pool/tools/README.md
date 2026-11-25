# capacity-pool tools

`render-network-interfaces.py` derives the `pool.networkInterfaces` value for
an EFA-capable instance type from the `NetworkInfo` block of one
`aws ec2 describe-instance-types` response
([#50](https://github.com/littlemex/distai-platform/issues/50)). How many
network cards a type has, which of them carry EFA and which `deviceIndex` the
EFA interface uses differ per instance family and are not visible in the
instance type name; a multi-card list is up to 33 near-identical entries that
a reviewer cannot check by eye. The generator replaces writing that list by
hand.

The script uses the Python 3 standard library only and never calls AWS. The
one AWS call happens once, by hand, when an instance type is onboarded, and its
result is committed under `fixtures/`. Issue #50 itself proposed a script that
takes `--region`/`--instance-type` and calls `DescribeInstanceTypes` directly;
this implementation instead takes `--describe-json` (a file holding the
already-captured, trimmed response) so that `gitops/tests/0.static.sh`'s own
check of this generator needs no AWS credentials, matching every check in
that file (a few other sections do reach the network for a public OCI
registry or schema catalog; none needs AWS credentials, which is the line
this generator stays on too). The onboarding section below is the one place
the live AWS call actually happens.

## Files

| File | Contents |
| --- | --- |
| `render-network-interfaces.py` | The generator |
| `exceptions.json` | Per-family facts the API does not return, keyed by family prefix (`p6-b300` from `p6-b300.48xlarge`) |
| `fixtures/<instance-type>.describe.json` | `InstanceTypes[0].NetworkInfo` of a real `describe-instance-types` response, plus a `_source` block (instance type, region, capture date, the exact command) this platform adds so a reviewer does not have to trust that the file matches the type it is named for |
| `fixtures/<instance-type>.networkInterfaces.yaml` | The generator's stdout for that response, byte for byte |

If a describe JSON carries `_source.instanceType`, the generator refuses when
it does not match `--instance-type` (a fixture captured for one instance type
accidentally passed for another is a refusal, not a silently wrong layout).
At the generator's own command line the field is optional, so a synthetic or
ad hoc `--describe-json` built for a test can still omit it. A *committed*
fixture under `fixtures/` is held to a higher bar: `gitops/tests/0.static.sh`
fails if any committed `*.describe.json` has no `_source.instanceType`, or one
that does not match its own file name, so every onboarded instance type here
carries a capture record whether or not a caller ever passes a mismatched
`--instance-type` at the generator directly.

## Layout rules

With `C` = `MaximumNetworkCards` and `E` = `EfaInfo.MaximumEfaInterfaces`:

| Case | Output | Instance types with a fixture |
| --- | --- | --- |
| `E == C` | card 0: `interface` at `deviceIndex` 0 and `efa-only` at `deviceIndex` 1; cards 1 to `C-1`: `efa-only` at `deviceIndex` 1 | `p5.48xlarge`, `p5e.48xlarge`, `p5en.48xlarge`, `p4d.24xlarge`, `p6-b200.48xlarge`, `g6e.48xlarge`, `g7.48xlarge`, `g6e.12xlarge` and `trn2.3xlarge` (`C == 1`, the same two entries as `values.yaml`'s own example) |
| `E == C - 1` | the `exceptions.json` entry's `excludedCard`: `interface` at `deviceIndex` 0 only; every other card: `efa-only` at the entry's `secondaryDeviceIndex` | `p6-b300.48xlarge` |
| no EFA, or any other `E` | refused | - |

Card 0 always has a separate `interface` entry because Karpenter's
`EC2NodeClass` requires a primary `interface` on `networkCardIndex` 0,
`deviceIndex` 0, and its `interfaceType` accepts only `interface` and
`efa-only`.

**The `E == C` row has no per-family allowlist of its own.** Unlike
`E == C - 1`, which `exceptions.json` gates explicitly, the generator renders
the `E == C` layout for *any* instance type whose numbers fit that shape,
including one this platform has not independently confirmed the `deviceIndex`
convention for (see Known issues below — `trn2.48xlarge` is exactly this
case). The actual safeguard is `gitops/tests/check_nic_layout.py`'s own
`GROUND_TRUTH` table: a fixture pair for an instance type with no entry there
fails the static check, so shipping a new `E == C` fixture is always a
deliberate, reviewed addition to that table, not something the generator
enforces on its own.

`p4d.24xlarge` is the only layout confirmed on real hardware by this platform
(EFA devices visible on the node and an `all_reduce_perf` run over EFA, see
[#50](https://github.com/littlemex/distai-platform/issues/50)). The others follow the sources cited in #50. The `p6-b300` entry in
`exceptions.json` carries `"confirmed": false` and its `source`, and the
generated header comment repeats that it is not confirmed.

## Onboarding an instance type

Run the AWS call by hand (read-only; any region that offers the type), then
render and check the result:

```bash
export INSTANCE_TYPE=p5en.48xlarge
export AWS_REGION=us-east-1
cd gitops/charts/capacity-pool/tools
aws ec2 describe-instance-types --region "${AWS_REGION}" \
  --instance-types "${INSTANCE_TYPE}" --query 'InstanceTypes[0]' --output json \
  > "/tmp/${INSTANCE_TYPE}.full.json"
python3 -c "
import json
d = json.load(open('/tmp/${INSTANCE_TYPE}.full.json'))
ni = d['NetworkInfo']
ni['_source'] = {
    'instanceType': d['InstanceType'],
    'region': '${AWS_REGION}',
    'capturedUtc': __import__('datetime').date.today().isoformat(),
    'command': \"aws ec2 describe-instance-types --instance-types ${INSTANCE_TYPE} --query 'InstanceTypes[0].NetworkInfo' --output json\",
}
json.dump(ni, open('fixtures/${INSTANCE_TYPE}.describe.json', 'w'), indent=2)
"
python3 render-network-interfaces.py \
  --describe-json "fixtures/${INSTANCE_TYPE}.describe.json" \
  --instance-type "${INSTANCE_TYPE}" \
  --exceptions exceptions.json \
  > "fixtures/${INSTANCE_TYPE}.networkInterfaces.yaml"
```

Besides the added `_source` block, the file is the API's `NetworkInfo`
response as returned; do not hand-edit the rest of it.

If the generator refuses with `E == C - 1`, find a named source that states
which card carries no EFA and which `deviceIndex` the other cards use, then
add an entry for the family and rerun:

```json
{
  "p6-b300": {
    "excludedCard": 0,
    "secondaryDeviceIndex": 0,
    "confirmed": false,
    "source": "where both facts come from, with commit-pinned URLs"
  }
}
```

`excludedCard` must be `0`: the generator always puts the primary interface on
the excluded card, which Karpenter only accepts on `networkCardIndex` 0 --
correct for `p6-b300`, where card 0 happens to be both the excluded one and
the primary one, but a family where those were different cards would need
different code here, not just a different value, so any other value is
refused instead. Set `confirmed` to `true` only after the layout has run on
real hardware.

Commit the two fixture files (and the `exceptions.json` entry, if any)
together, **and add the instance type to `GROUND_TRUTH` in
`gitops/tests/check_nic_layout.py`** in the same commit — the static check
fails a fixture pair with no `GROUND_TRUTH` entry on purpose (see "The `E ==
C` row has no per-family allowlist of its own" above), so skipping this step
is a red `0.static.sh`, not a silent gap.

## Using the output in a cell

The chart does not generate a cell's parameter file. Copy the printed list
into the cell's own `capacity-pool` values file under `pool.networkInterfaces`,
indented four spaces:

```bash
sed 's/^/    /' "fixtures/${INSTANCE_TYPE}.networkInterfaces.yaml"
```

```yaml
pool:
  networkInterfaces:
    # p5en.48xlarge: every network card carries EFA (E == C).
    # Generated by render-network-interfaces.py; do not edit by hand.
    - networkCardIndex: 0
      deviceIndex: 0
      interfaceType: interface
    - networkCardIndex: 0
      deviceIndex: 1
      interfaceType: efa-only
    - networkCardIndex: 1
      deviceIndex: 1
      interfaceType: efa-only
```

(the `p5en.48xlarge` list continues to `networkCardIndex: 15`.)

## Refusals

On every refusal the script prints one line to stderr, prints nothing to
stdout and exits with status 1:

| Input | Error text |
| --- | --- |
| No EFA | `render-network-interfaces: error: m7i.large: EFA is not supported (EfaSupported is false or EfaInfo.MaximumEfaInterfaces is absent/0); leave pool.networkInterfaces empty` |
| `E == C - 1`, family not in `exceptions.json` | `render-network-interfaces: error: p7-x.48xlarge: 16 EFA interfaces on 17 network cards (E == C - 1), and exceptions.json has no entry for family 'p7-x'; DescribeInstanceTypes does not say which card lacks EFA or which deviceIndex the others use, so add an entry from a named source instead of guessing` |
| Any other `E` | `render-network-interfaces: error: p5en.48xlarge: 14 EFA interfaces on 16 network cards is neither E == C nor E == C - 1; no layout rule covers it` |
| `excludedCard` other than `0` | `render-network-interfaces: error: exceptions.json['p6-b300'].excludedCard is 3; only 0 is supported. This code always puts the primary interface on the excluded card, which Karpenter only accepts on networkCardIndex 0 -- that is correct for p6-b300, where card 0 happens to be both the excluded one and the primary one, but would need different code (not just a different value here) for a family where those two were not the same card, so this refuses rather than emitting a layout Karpenter would reject` |
| `_source.instanceType` does not match `--instance-type` | `render-network-interfaces: error: p5e.48xlarge: --describe-json was captured for instance type 'p5.48xlarge' (its own _source.instanceType), not 'p5e.48xlarge'; pass the fixture captured for this instance type, not a borrowed one` |

## Known issues

- The API cannot tell an `E == C` family whose layout differs from the rule
  above. `trn2.48xlarge` returns `E == C` (16 and 16), so the generator renders
  the `E == C` layout for it, but #50 could not confirm that layout from any
  source. It has no fixture here; confirm the EFA devices and their
  `deviceIndex` on a first real node before relying on the output.
- A fixture records the API response at the time it was captured. A later
  change in the API's answer for the same type is not detected until the
  fixture is captured again.
- `p5.48xlarge.describe.json` and `p5e.48xlarge.describe.json` are
  byte-identical past their own `_source` blocks (independently captured in
  `us-east-1` and `us-west-2` respectively, re-confirmed live against both
  regions): the two families genuinely share the same `NetworkInfo` shape.
  `p6-b200.48xlarge`'s top-level `NetworkPerformance` ("3200 Gigabit") is not
  the sum of its eight cards' own `BaselineBandwidthInGbps` (200 each, 1600
  total); `g6e.48xlarge`'s top-level figure ("400 Gigabit") matches one
  card's bandwidth, not the four-card sum either. Both are reconfirmed live,
  not fixture artifacts; neither field is read by the generator, which uses
  only `MaximumNetworkCards` and `EfaInfo.MaximumEfaInterfaces`.
