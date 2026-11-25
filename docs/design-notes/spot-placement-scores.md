# Spot placement score snapshot used by issue #17

This note gives the full, reproducible provenance for the Spot placement score
values already summarized in issue #17's facts table ("Capacity survey" row)
and issue #17's comment about the `g7.2xlarge` / `g6e.xlarge` experiment
pairing. It exists so those values can be checked and refreshed without
re-deriving the call that produced them.

## What a Spot placement score is

Amazon EC2's `GetSpotPlacementScores` API returns a score from 1 (not likely)
to 10 (highly likely) for how likely a Spot request of a given size is to
succeed in a Region or Availability Zone, at the moment the call is made. It
is a public EC2 API, documented at
[Use Spot placement score to identify an optimal configuration](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-placement-score.html).
It is a different feature, with its own API action and its own entry in the
AWS Service Terms, from Amazon EC2 Capacity Manager; nothing in this note
comes from Capacity Manager.

**This is a single, point-in-time snapshot. A Spot placement score reflects
capacity conditions only at the moment the call was made and does not
guarantee that capacity will be available later, or that a launch at that
moment will succeed.** Treat every number below as history, not as a
current signal; re-run the command to get a current one.

## Values

| Instance type | Region | Score (1-10) | Captured at (UTC) | Target capacity | Command |
| --- | --- | --- | --- | --- | --- |
| `trn2.48xlarge` | `ap-northeast-1` | 9 | 2026-11-17T13:46:19Z | 1 unit | see [Command used](#command-used) |
| `trn2.3xlarge` | `ap-southeast-4` | 9 | 2026-11-17T13:46:19Z | 1 unit | see [Command used](#command-used) |
| `g7.2xlarge` | `ap-south-1`, `ap-southeast-2`, `eu-central-1`, `eu-south-2`, `sa-east-1`, `us-east-1`, `us-east-2`, `us-west-2` | 9 | 2026-11-17T13:46:19Z | 1 unit | see [Command used](#command-used) |
| `g7.2xlarge` | `eu-west-2` | 8 | 2026-11-17T13:46:19Z | 1 unit | see [Command used](#command-used) |
| `g6e.xlarge` | every Region it is offered in at the time (`ap-northeast-1`, `ap-northeast-3`, `ap-south-1`, `ap-south-2`, `eu-central-1`, `eu-north-1`, `eu-south-2`, `us-east-1`, `us-east-2`, `us-west-2`) | 1 | 2026-11-17T13:46:19Z | 1 unit | see [Command used](#command-used) |

These are exactly the values issue #17 already states in prose ("Spot
placement score 9 for `trn2.48xlarge` in `ap-northeast-1`, `trn2.3xlarge` in
`ap-southeast-4`, `g7.2xlarge` in many Regions; `g6e.xlarge` 1 everywhere")
and the comment on issue #17 that pairs `g7.2xlarge` (score 9) against
`g6e.xlarge` (score 1, everywhere) as the failing case for a launch-fallback
experiment. This note adds the exact timestamp, the target capacity used,
and a runnable command; it does not add any new value beyond what issue #17
already made public.

## Command used

The score was read with the Region-level form of the API (one call per
instance type, across every Region that instance type was offered in at the
time, found separately with `describe-instance-type-offerings`). The AWS CLI
equivalent, which anyone can re-run, is:

```bash
export INSTANCE_TYPE=trn2.48xlarge
export REGIONS="ap-northeast-1 ap-south-1 ap-south-2 ca-central-1 us-east-2 us-west-2"

aws ec2 get-spot-placement-scores \
  --instance-types "$INSTANCE_TYPE" \
  --target-capacity 1 \
  --target-capacity-unit-type units \
  --region-names $REGIONS
```

Substitute `INSTANCE_TYPE` and `REGIONS` (the Regions the type is offered in)
to reproduce any row above. `REGIONS` does not change the Region the call is
billed or throttled against; `get-spot-placement-scores` is a global-ish call
that can be issued from any Region and scores every Region named in
`--region-names`.

## What this note is not

- Not a live dashboard. Nothing in this platform calls this API on a
  schedule or wires its output into any chart, controller or dashboard;
  the table above is a manually captured, dated snapshot.
- Not a capacity guarantee for this platform's design (issue #17) or for
  any `-rsv`/`-od`/`-flex` pool. Issue #17's design treats a Spot
  placement score only as one input next to Capacity Block offerings and
  the launch ledger, never as proof that a launch will succeed.
- Not Amazon EC2 Capacity Manager data. See issue #29 for how this
  platform treats EC2 Capacity Manager Data under AWS Service Terms
  section 5.9 (never published, in any form); Spot placement score is a
  separate feature and is not subject to that rule, but issue #29 flags
  that Spot placement score's own Service Terms have not yet been
  independently checked, and treats checking them as a follow-up.
