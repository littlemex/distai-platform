# Spot placement score snapshot used by issue #17

This note gives the full, reproducible provenance for the Spot placement score values already summarized in issue #17's facts table ("Capacity survey" row) and issue #17's comment about the `g7.2xlarge` / `g6e.xlarge` experiment pairing, and adds a small number of further values from the same survey and the same API calls that issue #17's prose did not separately state. It exists so every value below can be checked and refreshed without re-deriving the call that produced it.

## What a Spot placement score is

Amazon EC2's `GetSpotPlacementScores` API returns a score from 1 (not likely) to 10 (highly likely) for how likely a Spot request of a given size is to succeed in a Region or Availability Zone, at the moment the call is made. It is a public EC2 API, documented at [Use Spot placement score to identify an optimal configuration](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html). It is a different feature, with its own API action and its own entry in the AWS Service Terms, from Amazon EC2 Capacity Manager; nothing in this note comes from Capacity Manager.

**This is a single, point-in-time snapshot. A Spot placement score reflects capacity conditions only at the moment the call was made and does not guarantee that capacity will be available later, or that a launch at that moment will succeed.** Treat every number below as history, not as a current signal; re-run the matching command below to get a current one.

## Why these values may be published

Issue #17's facts table and a follow-up comment already state four of the values below in prose, with no date, no target capacity, and no reproducing command attached. Two further values (both for `g7.2xlarge`) are added here because they come from the exact same survey and the exact same API call as the ones issue #17 already states, and leaving them out while listing the rest of that same call's Regions would misrepresent what the call actually returned. Publishing a value beyond what issue #17's prose already made public needed its own maintainer decision, separate from the general question of whether Spot placement score is EC2 Capacity Manager Data: [issue #29's maintainer-decision comment](https://github.com/littlemex/distai-platform/issues/29#issuecomment-7162643245), dated 2026-11-25, is that decision. It allows publishing any value read only from `GetSpotPlacementScores` (never from `GetCapacityManagerSupportabilityScores` or any other EC2 Capacity Manager action) as long as it carries the date and time read, the Region or Availability Zone scope, the instance type, the target capacity used, and the command used to read it, and is labeled a point-in-time snapshot rather than a guarantee. Every row below follows that rule; this note is the committed record issue #29's own comment points to instead of restating the rule itself.

## Values

| Instance type | Region | Score (1-10) | Survey run completed (UTC) | Target capacity | Command |
| --- | --- | --- | --- | --- | --- |
| `trn2.48xlarge` | `ap-northeast-1` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.48xlarge](#command-for-trn248xlarge) |
| `trn2.3xlarge` | `ap-southeast-4` | 9 | 2026-11-17T13:46:19Z | 1 unit | [trn2.3xlarge](#command-for-trn23xlarge) |
| `g7.2xlarge` | `ap-south-1`, `ap-southeast-2`, `eu-central-1`, `eu-south-2`, `sa-east-1`, `us-east-1`, `us-east-2`, `us-west-2` | 9 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-west-2` | 8 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g7.2xlarge` | `eu-north-1` | 1 | 2026-11-17T13:46:19Z | 1 unit | [g7.2xlarge](#command-for-g72xlarge) |
| `g6e.xlarge` | every Region it was offered in at the time the score was read (`ap-northeast-1`, `ap-northeast-3`, `ap-south-1`, `ap-south-2`, `eu-central-1`, `eu-north-1`, `eu-south-2`, `us-east-1`, `us-east-2`, `us-west-2`) | 1 | 2026-11-17T13:46:19Z | 1 unit | [g6e.xlarge](#command-for-g6exlarge) |

The `trn2.48xlarge`, `trn2.3xlarge` and `g6e.xlarge` rows restate exactly what issue #17 already states in prose ("Spot placement score 9 for `trn2.48xlarge` in `ap-northeast-1`, `trn2.3xlarge` in `ap-southeast-4`, `g7.2xlarge` in many Regions; `g6e.xlarge` 1 everywhere"), now with their exact Region scope and the fields the section above requires. The three `g7.2xlarge` rows together are the complete set of Regions that single `get-spot-placement-scores` call returned a score for; the first of the three restates issue #17's "many Regions" at score 9, and the other two (`eu-west-2` at 8, `eu-north-1` at 1) are the additional values the section above explains.

### Survey run completed, not a per-call timestamp

The single timestamp in every row above is when the whole capacity survey script finished, not when any individual `get-spot-placement-scores` call ran. That script made one such call per instance type (four calls total for the four instance types above) in the same run, and also collected unrelated data in the same run (instance-type offerings, Spot price history, Capacity Block offerings, and vCPU quotas, none of which are published here); it recorded only the time the whole run finished, not a separate timestamp per call. Treat the timestamp above as an upper bound on when each of the four calls was actually made, not an exact per-call capture time.

## Commands used

Each instance type below was read with its own `get-spot-placement-scores` call, with `--region-names` listing every Region that instance type was offered in at the time (found separately with `describe-instance-type-offerings`). Each command is complete and literal: paste it as written, with no variable to substitute, and it reproduces the matching row or rows above exactly.

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
  --region-names ap-northeast-1 ap-northeast-3 ap-south-1 ap-south-2 eu-central-1 eu-north-1 eu-south-2 us-east-1 us-east-2 us-west-2
```

`get-spot-placement-scores` can be issued from any Region and scores every Region named in `--region-names`; it does not need to be run from, or billed against, any Region in that list.

## What this note is not

- Not a live dashboard. Nothing in this platform calls this API on a schedule or wires its output into any chart, controller or dashboard; the table above is a manually captured, dated snapshot.
- Not a capacity guarantee for this platform's design (issue #17) or for any `-rsv`/`-od`/`-flex` pool. Issue #17's design treats a Spot placement score only as one input next to Capacity Block offerings and the launch ledger, never as proof that a launch will succeed.
- Not Amazon EC2 Capacity Manager data. See issue #29 for how this platform treats EC2 Capacity Manager Data under AWS Service Terms section 5.9 (never published, in any form, and nothing about that rule changes here). Spot placement score is a separate API action with its own entry in the Service Terms; [the maintainer's 2026-11-25 comment on issue #29](https://github.com/littlemex/distai-platform/issues/29#issuecomment-7162643245) is the specific decision that allows publishing the values above, and this note relies on that comment directly rather than inferring publication is safe by contrast with a different feature's clause.
