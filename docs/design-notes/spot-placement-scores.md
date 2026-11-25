# Spot placement score snapshot used by issue #17

This note gives the full, reproducible provenance for the Spot placement score values already summarized in issue #17's facts table ("Capacity survey" row), and adds two further table rows (both for `g7.2xlarge`) from the same survey and the same API call that issue #17's prose did not separately state. Issue #17 also pairs `g7.2xlarge` against `g6e.xlarge` (score 1 everywhere) in a comment about a launch-fallback experiment; this note does not add a `g6e.xlarge` row, for the reason given below the table. It exists so every value below can be checked and refreshed without re-deriving the call that produced it.

## What a Spot placement score is

Amazon EC2's `GetSpotPlacementScores` API returns a score from 1 (not likely) to 10 (highly likely) for how likely a Spot request of a given size is to succeed in a Region or Availability Zone, at the moment the call is made. It is a public EC2 API, documented at [Use Spot placement score to identify an optimal configuration](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html) and in the [API reference](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_GetSpotPlacementScores.html). It is a separate EC2 API action from Amazon EC2 Capacity Manager; nothing in this note comes from Capacity Manager.

**This is a single, point-in-time snapshot. A Spot placement score reflects capacity conditions only at the moment the call was made and does not guarantee that capacity will be available later, or that a launch at that moment will succeed.** Treat every number below as history, not as a current signal.

## Why these values may be published

A value stated only in prose, the way issue #17's facts table and a follow-up comment already state three of the five rows below, carries no capture time, no target capacity and no reproducing command, so a reader cannot tell a stale value from a current one or check it without re-deriving the call. Two further rows (both for `g7.2xlarge`) are added here because they come from the exact same survey and the exact same API call as the one issue #17 already states; that call returned three distinct scores (9, 8 and 1), and leaving out the two Regions scored differently from the rest (`eu-west-2` at 8, `eu-north-1` at 1) while listing every other Region that same call scored would misrepresent what that one call actually returned. Publishing a value beyond issue #17's own prose is governed by [issue #29's 2026-11-25 comment](https://github.com/littlemex/distai-platform/issues/29#issuecomment-7162643245), separate from the general question of whether Spot placement score is EC2 Capacity Manager Data: it permits publishing any value read only from `GetSpotPlacementScores` (never from `GetCapacityManagerSupportabilityScores` or any other EC2 Capacity Manager action), carrying the date and time read, the Region or Availability Zone scope, the instance type, the target capacity used, and the exact command used to read it, and labeled a point-in-time snapshot rather than a guarantee. As that comment itself states, this is the maintainer's own working decision for this platform's purposes, not a legal conclusion. Every row below carries all five of those fields; the one limitation disclosed rather than hidden is in "Captured time is approximate, not a per-call instant" below.

## Values

| Instance type | Region | Score (1-10) | Captured (UTC, approximate) | Target capacity | Command |
| --- | --- | --- | --- | --- | --- |
| `trn2.48xlarge` | `ap-northeast-1` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.48xlarge](#command-for-trn248xlarge) |
| `trn2.3xlarge` | `ap-southeast-4` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.3xlarge](#command-for-trn23xlarge) |
| `g7.2xlarge` | `ap-south-1`, `ap-southeast-2`, `eu-central-1`, `eu-south-2`, `sa-east-1`, `us-east-1`, `us-east-2`, `us-west-2` | 9 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-west-2` | 8 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-north-1` | 1 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |

The `trn2.48xlarge` and `trn2.3xlarge` rows restate exactly the single value issue #17's prose already states for each type (`ap-northeast-1` at 9, `ap-southeast-4` at 9). The three `g7.2xlarge` rows together are the complete set of Regions that single call returned a score for; the first of the three restates issue #17's "many Regions" at score 9, and the other two (`eu-west-2` at 8, `eu-north-1` at 1) are the two further table rows the section above explains.

### Why there is no `g6e.xlarge` row

Issue #29's decision requires the exact command used to read a value. `g6e.xlarge` was offered in 11 Regions at the time of this survey, but AWS's own API reference documents a maximum of 10 items for a `GetSpotPlacementScores` request's Region names, and this survey recorded a score for only 10 Regions. This note has no way to state, and no citable source to confirm, exactly which Regions the original request named, so it cannot give `g6e.xlarge` a command that meets the decision's requirement. Issue #17's own prose statement ("`g6e.xlarge` 1 everywhere") remains the only public record of that value; this note does not restate it as a full row, and does not add a new, less complete record in its place.

### Captured time is approximate, not a per-call instant

The single timestamp in every row above is one run-level time, recorded once for the whole capacity survey that produced these values, not a separate time recorded for each of the `get-spot-placement-scores` calls that produced the rows above; treat it as approximate, not as an exact, per-call instant. The script that produced this survey is not part of this platform's own repository, so this note cannot point a reader to a committed line showing exactly how or when within the run that timestamp is set.

## Commands used

Each instance type below was read with the literal `boto3` call shown first, which is the exact command the decision above requires; an equivalent AWS CLI invocation of the same action with the same parameters follows each one, for a reader who does not have `boto3` set up. Running either reproduces how the matching row's value was obtained, with the same parameters, not necessarily the same score, since a score is a point-in-time read (see above). `RegionNames`/`--region-names` was set to every Region that instance type was offered in at the time (found separately with `describe-instance-type-offerings`). For `trn2.48xlarge` and `trn2.3xlarge`, the call below returns a score for every Region it names, not only the single Region shown in the Values table; the table's single row is the one of those Regions issue #17's prose already states.

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

`get-spot-placement-scores` can be issued from any Region; it does not need to be run from, or billed against, any Region named in `--region-names`.

## What this note is not

- Not a live dashboard. Nothing in this platform calls this API on a schedule or wires its output into any chart, controller or dashboard; the table above is a manually captured, dated snapshot.
- Not a capacity guarantee for this platform's design (issue #17) or for any `-rsv`/`-od`/`-flex` pool. Issue #17's design treats a Spot placement score only as one input next to Capacity Block offerings and the launch ledger, never as proof that a launch will succeed.
- Not Amazon EC2 Capacity Manager data. See issue #29 for how this platform treats EC2 Capacity Manager Data under AWS Service Terms section 5.9 (never published, in any form, and nothing about that rule changes here). Spot placement score is a separate API action; this note relies on [the maintainer's 2026-11-25 decision on issue #29](https://github.com/littlemex/distai-platform/issues/29#issuecomment-7162643245) to publish the values above, not on an inference from EC2 Capacity Manager's own, different clause, and that decision itself is the maintainer's own working call for this platform's purposes, not a legal conclusion.
