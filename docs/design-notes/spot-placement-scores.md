# Spot placement score snapshot used by issue #17

This note gives the full, reproducible provenance for the Spot placement score values already summarized in issue #17's facts table ("Capacity survey" row) and issue #17's comment about the `g7.2xlarge` / `g6e.xlarge` experiment pairing, and adds two further table rows (both for `g7.2xlarge`) from the same survey and the same API call that issue #17's prose did not separately state. It also mentions, in prose below the table rather than as rows of their own, seven further score values from the `trn2.48xlarge` and `trn2.3xlarge` calls, to show that the single value each of those two rows states is not a cherry-picked best case. It exists so every value below can be checked and refreshed without re-deriving the call that produced it.

## What a Spot placement score is

Amazon EC2's `GetSpotPlacementScores` API returns a score from 1 (not likely) to 10 (highly likely) for how likely a Spot request of a given size is to succeed in a Region or Availability Zone, at the moment the call is made. It is a public EC2 API, documented at [Use Spot placement score to identify an optimal configuration](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html) and in the [API reference](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_GetSpotPlacementScores.html). It is a separate EC2 API action from Amazon EC2 Capacity Manager; nothing in this note comes from Capacity Manager. The API reference states that a response returns a score for the top 10 Regions or Availability Zones only: naming more than that in a request does not get every one of them scored, which matters for one row below.

**This is a single, point-in-time snapshot. A Spot placement score reflects capacity conditions only at the moment the call was made and does not guarantee that capacity will be available later, or that a launch at that moment will succeed.** Treat every number below as history, not as a current signal.

## Why these values may be published

A value stated only in prose, the way issue #17's facts table and a follow-up comment already state four of the six rows below, carries no capture time, no target capacity and no reproducing command, so a reader cannot tell a stale value from a current one or check it without re-deriving the call. Two further rows (both for `g7.2xlarge`) are added here because they come from the exact same survey and the exact same API call as the ones issue #17 already states; that call returned three distinct scores (9, 8 and 1), and leaving out the two Regions scored differently from the rest (`eu-west-2` at 8, `eu-north-1` at 1) while listing every other Region that same call scored would misrepresent what that one call actually returned. Publishing a value beyond issue #17's own prose is governed by [issue #29's 2026-11-25 comment](https://github.com/littlemex/distai-platform/issues/29#issuecomment-7162643245), separate from the general question of whether Spot placement score is EC2 Capacity Manager Data: it permits publishing any value read only from `GetSpotPlacementScores` (never from `GetCapacityManagerSupportabilityScores` or any other EC2 Capacity Manager action), carrying the date and time read, the Region or Availability Zone scope, the instance type, the target capacity used, and the exact command used to read it, and labeled a point-in-time snapshot rather than a guarantee. As that comment itself states, this is the maintainer's own working decision for this platform's purposes, not a legal conclusion. Every row below follows that rule. Two limitations are disclosed, not hidden: the shared timestamp (see "Captured time is approximate, not a per-call instant" below) is approximate, not a separately recorded time per call; and the `g6e.xlarge` command's 11 named Regions (see "Commands used" below) are recorded as what was used, not independently citable beyond re-running the command and observing the same capped result.

## Values

| Instance type | Region | Score (1-10) | Captured (UTC, approximate) | Target capacity | Command |
| --- | --- | --- | --- | --- | --- |
| `trn2.48xlarge` | `ap-northeast-1` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.48xlarge](#command-for-trn248xlarge) |
| `trn2.3xlarge` | `ap-southeast-4` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.3xlarge](#command-for-trn23xlarge) |
| `g7.2xlarge` | `ap-south-1`, `ap-southeast-2`, `eu-central-1`, `eu-south-2`, `sa-east-1`, `us-east-1`, `us-east-2`, `us-west-2` | 9 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-west-2` | 8 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-north-1` | 1 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g6e.xlarge` | `ap-northeast-1`, `ap-northeast-3`, `ap-south-1`, `ap-south-2`, `eu-central-1`, `eu-north-1`, `eu-south-2`, `us-east-1`, `us-east-2`, `us-west-2` | 1 | 2026-11-17T13:46:19Z | 1 unit | [g6e.xlarge](#command-for-g6exlarge) |

The `trn2.48xlarge` and `trn2.3xlarge` rows restate exactly the single value issue #17's prose already states for each type (`ap-northeast-1` at 9, `ap-southeast-4` at 9); only that one Region each is given its own row, since issue #17's prose never referenced the rest and no later Issue has needed a reproducible record of them yet. The other Regions those two calls also scored are mentioned here, not tabled, for transparency rather than as a published record of their own: `trn2.48xlarge`'s own call also scored `ap-south-1` (7), `ap-south-2` (9), `ca-central-1` (1), `us-west-2` (5) and `us-east-2` (9) — two of those five (`ap-south-2`, `us-east-2`) at the same score as `ap-northeast-1`, not all of them at a different score; `trn2.3xlarge`'s own call also scored `ap-south-2` (1) and `sa-east-1` (1), both different from `ap-southeast-4`'s 9. Should a later Issue need a reproducible record of any of these, it can be added as its own row under the same decision, using the same call's own command and target capacity. The `g6e.xlarge` row matches issue #17's prose ("1 everywhere") for every Region that call returned a score for, with one nuance prose did not capture: the call was given every Region `g6e.xlarge` was offered in at the time (11, including `ap-northeast-2`), and the response, capped at the API's own top-10 limit, came back with a score for only 10 of them; `ap-northeast-2` is missing from the row above because it did not come back with a score. The three `g7.2xlarge` rows together are the complete set of Regions that single call returned a score for (ten, matching the ten Regions that type was offered in at the time, so nothing was lost to the API's top-10 cap here); the first of the three restates issue #17's "many Regions" at score 9, and the other two (`eu-west-2` at 8, `eu-north-1` at 1) are the two further table rows the section above explains.

### Captured time is approximate, not a per-call instant

The single timestamp in every row above is one run-level time, recorded once for the whole capacity survey that produced these values, not a separate time recorded for each of the four `get-spot-placement-scores` calls that produced the rows above; treat it as approximate, not as an exact, per-call instant. The script that produced this survey is not part of this platform's own repository, so this note cannot point a reader to a committed line showing exactly how or when within the run that timestamp is set.

## Commands used

Each instance type below was read with the literal `boto3` call shown first, which is the exact command the decision above requires for every type except `g6e.xlarge` (see that type's own note below); an equivalent AWS CLI invocation of the same action with the same parameters follows each one, for a reader who does not have `boto3` set up. Running either reproduces how the matching row's value was obtained, with the same parameters, not necessarily the same score, since a score is a point-in-time read (see above). `RegionNames`/`--region-names` was set to every Region that instance type was offered in at the time (found separately with `describe-instance-type-offerings`). For `trn2.48xlarge` and `trn2.3xlarge`, the call below returns a score for every Region it names, not only the single Region shown in the Values table; the table's single row is the one of those Regions issue #17's prose already states.

The `g6e.xlarge` block below names all 11 Regions that type was offered in at the time, as recorded by whoever ran the survey; only 10 of them appear in the Values table, for the reason given above. AWS's own API reference (linked above) separately documents a maximum of 10 items for `RegionName.N`. This note has no citable, public source to explain that discrepancy beyond what is already shown here, so, unlike the other three blocks, the `g6e.xlarge` block is this note's own record of the parameters used rather than an independently verifiable exact command; a reader can check that it behaves consistently with the Values table above (11 named, 10 scored) by running it, but cannot independently confirm from this note alone that 11 were truly named in the original read.

### Command for trn2.48xlarge

```python
boto3.client("ec2").get_spot_placement_scores(
    InstanceTypes=["trn2.48xlarge"],
    TargetCapacity=1,
    TargetCapacityUnitType="units",
    RegionNames=["ap-northeast-1", "ap-south-1", "ap-south-2", "ca-central-1", "us-east-2", "us-west-2"],
)
```

AWS CLI equivalent:

```bash
aws ec2 get-spot-placement-scores \
  --instance-types trn2.48xlarge \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names ap-northeast-1 ap-south-1 ap-south-2 ca-central-1 us-east-2 us-west-2
```

### Command for trn2.3xlarge

```python
boto3.client("ec2").get_spot_placement_scores(
    InstanceTypes=["trn2.3xlarge"],
    TargetCapacity=1,
    TargetCapacityUnitType="units",
    RegionNames=["ap-south-2", "ap-southeast-4", "sa-east-1"],
)
```

AWS CLI equivalent:

```bash
aws ec2 get-spot-placement-scores \
  --instance-types trn2.3xlarge \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names ap-south-2 ap-southeast-4 sa-east-1
```

### Command for g7.2xlarge

```python
boto3.client("ec2").get_spot_placement_scores(
    InstanceTypes=["g7.2xlarge"],
    TargetCapacity=1,
    TargetCapacityUnitType="units",
    RegionNames=["ap-south-1", "ap-southeast-2", "eu-central-1", "eu-north-1", "eu-south-2", "eu-west-2", "sa-east-1", "us-east-1", "us-east-2", "us-west-2"],
)
```

AWS CLI equivalent:

```bash
aws ec2 get-spot-placement-scores \
  --instance-types g7.2xlarge \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names ap-south-1 ap-southeast-2 eu-central-1 eu-north-1 eu-south-2 eu-west-2 sa-east-1 us-east-1 us-east-2 us-west-2
```

### Command for g6e.xlarge

```python
boto3.client("ec2").get_spot_placement_scores(
    InstanceTypes=["g6e.xlarge"],
    TargetCapacity=1,
    TargetCapacityUnitType="units",
    RegionNames=["ap-northeast-1", "ap-northeast-2", "ap-northeast-3", "ap-south-1", "ap-south-2", "eu-central-1", "eu-north-1", "eu-south-2", "us-east-1", "us-east-2", "us-west-2"],
)
```

AWS CLI equivalent:

```bash
aws ec2 get-spot-placement-scores \
  --instance-types g6e.xlarge \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names ap-northeast-1 ap-northeast-2 ap-northeast-3 ap-south-1 ap-south-2 eu-central-1 eu-north-1 eu-south-2 us-east-1 us-east-2 us-west-2
```

`get-spot-placement-scores` can be issued from any Region; it does not need to be run from, or billed against, any Region named in `--region-names`.

## What this note is not

- Not a live dashboard. Nothing in this platform calls this API on a schedule or wires its output into any chart, controller or dashboard; the table above is a manually captured, dated snapshot.
- Not a capacity guarantee for this platform's design (issue #17) or for any `-rsv`/`-od`/`-flex` pool. Issue #17's design treats a Spot placement score only as one input next to Capacity Block offerings and the launch ledger, never as proof that a launch will succeed.
- Not Amazon EC2 Capacity Manager data. See issue #29 for how this platform treats EC2 Capacity Manager Data under AWS Service Terms section 5.9 (never published, in any form, and nothing about that rule changes here). Spot placement score is a separate API action; this note relies on [the maintainer's 2026-11-25 decision on issue #29](https://github.com/littlemex/distai-platform/issues/29#issuecomment-7162643245) to publish the values above, not on an inference from EC2 Capacity Manager's own, different clause, and that decision itself is the maintainer's own working call for this platform's purposes, not a legal conclusion.
