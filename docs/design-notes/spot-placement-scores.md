# Spot placement score snapshot used by issue #17

This note gives the full, reproducible provenance for the Spot placement score values already summarized in issue #17's facts table ("Capacity survey" row) and issue #17's comment about the `g7.2xlarge` / `g6e.xlarge` experiment pairing, and adds two further values from the same survey and the same API call that issue #17's prose did not separately state. It exists so every value below can be checked and refreshed without re-deriving the call that produced it.

## What a Spot placement score is

Amazon EC2's `GetSpotPlacementScores` API returns a score from 1 (not likely) to 10 (highly likely) for how likely a Spot request of a given size is to succeed in a Region or Availability Zone, at the moment the call is made. It is a public EC2 API, documented at [Use Spot placement score to identify an optimal configuration](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html) and in the [API reference](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_GetSpotPlacementScores.html). It is a separate EC2 API action from Amazon EC2 Capacity Manager; nothing in this note comes from Capacity Manager. The API reference states that a response returns a score for the top 10 Regions or Availability Zones only: naming more than that in a request does not get every one of them scored, which matters for one row below.

**This is a single, point-in-time snapshot. A Spot placement score reflects capacity conditions only at the moment the call was made and does not guarantee that capacity will be available later, or that a launch at that moment will succeed.** Treat every number below as history, not as a current signal.

## Why these values may be published

A value stated only in prose, the way issue #17's facts table and a follow-up comment already state four of the six rows below, carries no capture time, no target capacity and no reproducing command, so a reader cannot tell a stale value from a current one or check it without re-deriving the call. Two further rows (both for `g7.2xlarge`) are added here because they come from the exact same survey and the exact same API call as the ones issue #17 already states; leaving them out while listing the Regions from that call with the higher of its two differing scores would misrepresent what that one call actually returned. Publishing a value beyond issue #17's own prose is governed by [issue #29's 2026-11-25 comment](https://github.com/littlemex/distai-platform/issues/29#issuecomment-7162643245), separate from the general question of whether Spot placement score is EC2 Capacity Manager Data: it permits publishing any value read only from `GetSpotPlacementScores` (never from `GetCapacityManagerSupportabilityScores` or any other EC2 Capacity Manager action), carrying the date and time read, the Region or Availability Zone scope, the instance type, the target capacity used, and the command used to read it, and labeled a point-in-time snapshot rather than a guarantee. As that comment itself states, this is the maintainer's own working decision for this platform's purposes, not a legal conclusion. Every row below follows that rule, with the one limitation the "Survey run completed, not a per-call timestamp" section below discloses rather than hides: the shared timestamp is a run-level upper bound, not a separately recorded time per call.

## Values

| Instance type | Region | Score (1-10) | Survey run completed (UTC) | Target capacity | Command |
| --- | --- | --- | --- | --- | --- |
| `trn2.48xlarge` | `ap-northeast-1` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.48xlarge](#command-for-trn248xlarge) |
| `trn2.3xlarge` | `ap-southeast-4` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.3xlarge](#command-for-trn23xlarge) |
| `g7.2xlarge` | `ap-south-1`, `ap-southeast-2`, `eu-central-1`, `eu-south-2`, `sa-east-1`, `us-east-1`, `us-east-2`, `us-west-2` | 9 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-west-2` | 8 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-north-1` | 1 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g6e.xlarge` | `ap-northeast-1`, `ap-northeast-3`, `ap-south-1`, `ap-south-2`, `eu-central-1`, `eu-north-1`, `eu-south-2`, `us-east-1`, `us-east-2`, `us-west-2` | 1 | 2026-11-17T13:46:19Z | 1 unit | [g6e.xlarge](#command-for-g6exlarge) |

The `trn2.48xlarge` and `trn2.3xlarge` rows restate exactly the single value issue #17's prose already states for each type (`ap-northeast-1` at 9, `ap-southeast-4` at 9); they are a deliberate subset, not the complete set of Regions those two calls returned (`trn2.48xlarge`'s own call also scored `ap-south-1`, `ap-south-2`, `ca-central-1` and `us-west-2`, at different scores; `trn2.3xlarge`'s own call also scored `ap-south-2` and `sa-east-1` — not reproduced here, since issue #17 did not reference them and no later Issue has needed them yet). The `g6e.xlarge` row matches issue #17's prose ("1 everywhere") for every Region that call returned a score for, with one nuance prose did not capture: the call named 11 candidate Regions (every Region `g6e.xlarge` was offered in at the time, including `ap-northeast-2`) and the response, capped at the API's own top-10 limit, came back with a score for only 10 of them; `ap-northeast-2` is missing from the row above because it did not come back with a score, not because it was left out. The three `g7.2xlarge` rows together are the complete set of Regions that single call returned a score for (ten, matching the ten Regions that type was offered in at the time, so nothing was lost to the API's top-10 cap here); the first of the three restates issue #17's "many Regions" at score 9, and the other two (`eu-west-2` at 8, `eu-north-1` at 1) are the additional values the section above explains.

### Survey run completed, not a per-call timestamp

The single timestamp in every row above is when the whole capacity survey script finished, not when any individual `get-spot-placement-scores` call ran. That script made one such call per instance type (four calls total for the four instance types above) in the same run, and also collected unrelated data in the same run (instance-type offerings, Spot price history, Capacity Block offerings, and vCPU quotas, none of which are published here); the timestamp is written by the script's final statement, after every one of those calls (and every other call the script makes) has already returned, so it is an upper bound on when each of the four calls was actually made, not a lower bound and not an exact per-call capture time.

## Commands used

Each instance type below was read by a script calling the `get_spot_placement_scores` boto3 action directly, with `RegionNames` set to every Region that instance type was offered in at the time (found separately with `describe-instance-type-offerings`). The blocks below are the AWS CLI's equivalent invocation of that same action with the same parameters, not a transcript of a CLI session that was actually run; running one reproduces how the matching row's value was obtained, with the same parameters, not necessarily the same score, since a score is a point-in-time read (see above). For `trn2.48xlarge` and `trn2.3xlarge`, the command below returns a score for every Region it names, not only the single Region shown in the Values table; the table's single row is the one of those Regions issue #17's prose already states. The `g6e.xlarge` command below names 11 Regions, matching what the script actually sent; only 10 of them appear in the Values table, for the reason given above.

### Command for trn2.48xlarge

```bash
aws ec2 get-spot-placement-scores \
  --instance-types trn2.48xlarge \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names ap-northeast-1 ap-south-1 ap-south-2 ca-central-1 us-east-2 us-west-2
```

### Command for trn2.3xlarge

```bash
aws ec2 get-spot-placement-scores \
  --instance-types trn2.3xlarge \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names ap-south-2 ap-southeast-4 sa-east-1
```

### Command for g7.2xlarge

```bash
aws ec2 get-spot-placement-scores \
  --instance-types g7.2xlarge \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names ap-south-1 ap-southeast-2 eu-central-1 eu-north-1 eu-south-2 eu-west-2 sa-east-1 us-east-1 us-east-2 us-west-2
```

### Command for g6e.xlarge

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
