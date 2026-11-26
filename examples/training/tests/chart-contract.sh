# shellcheck shell=bash
# What the tests of examples/training/pytorch-ddp assume about the chart
# from the outside: the values.yaml key names they set, and the log lines
# and checkpoint object keys the training script is expected to produce.
# Sourced by 0.static.sh and 1.e2e.sh, never executed. Each key is a dotted
# path for `helm template --set`.
#
# NOTE: every name below was chosen by the test author from issue #34's
# own description of the chart (a JobSet with a kueue.x-k8s.io/queue-name
# label, a replica count that is "the only difference" between the
# single-node and two-node variant, a ServiceAccount meant for an EKS Pod
# Identity association, a step-numbered checkpoint to s3://<bucket>/<prefix>/
# every N steps), not read from the chart itself. If the chart names a
# value differently, change the path here -- this is the one place both
# scripts read it from. What each check asserts about the rendered
# output (check_training_render.py) does not depend on these names: it is
# given the value that was set and looks for it in the rendered objects.
# shellcheck disable=SC2034 # read by the sourcing script

# -> the JobSet's metadata.labels["kueue.x-k8s.io/queue-name"]
TRAINING_KEY_QUEUE_NAME="kueue.queueName"
# -> spec.replicatedJobs[0].replicas (pods, one per node, in the one group)
TRAINING_KEY_REPLICAS="workers.replicas"
# -> the pod's own GPU limit and torchrun --nproc-per-node
TRAINING_KEY_GPUS_PER_POD="workers.gpusPerNode"
# -> the pod template's serviceAccountName and the rendered ServiceAccount
TRAINING_KEY_SERVICE_ACCOUNT="serviceAccount.name"
# -> where the training script writes and reads its checkpoints
TRAINING_KEY_CHECKPOINT_BUCKET="checkpoint.bucket"
TRAINING_KEY_CHECKPOINT_PREFIX="checkpoint.prefix"
# -> the AWS_REGION the training script's own S3 client uses; the
# container's entrypoint exits before running anything if this is empty
TRAINING_KEY_CHECKPOINT_REGION="checkpoint.region"
# -> how often (in steps) a checkpoint is written, and how many steps run
TRAINING_KEY_CHECKPOINT_EVERY="training.checkpointEvery"
TRAINING_KEY_TOTAL_STEPS="training.totalSteps"

# NOTE: the training script's own observable contract, also chosen by the
# test author (issue #34 says the script "saves a step-numbered checkpoint
# to s3://<bucket>/<prefix>/ every N steps and loads the latest one on
# start if present", but not how either is observable from outside):
#   - every checkpoint object key under the prefix carries the step it was
#     taken at as the LAST run of decimal digits in the key, read relative
#     to the prefix (<prefix>/step-00000040.pt and <prefix>/ckpt-40/state.pt
#     both read as 40; <prefix>/step-40/model-v2.pt would read as 2, so a
#     file name with digits of its own does not satisfy this);
#   - on start, when it loads a checkpoint, the script prints one line
#     matching TRAINING_RESUME_LOG_REGEX below on stdout/stderr, with the
#     step it resumed from as the first capture group; when it finds none,
#     it prints nothing matching that pattern.
# 1.e2e.sh greps the restarted Pods' logs for exactly this pattern.
TRAINING_RESUME_LOG_REGEX='resuming from step ([0-9]+)'
# The static part of the line above, with no regex metacharacters at all
# (not derived from TRAINING_RESUME_LOG_REGEX by stripping a suffix: that
# regex's own capture group opens with "(" before its "[0-9]" character
# class closes, so a generic "strip from the first '[' or '(' onward"
# trick cannot produce a valid prefix for every regex this file could
# ever hold -- a fixed literal, kept in sync with the regex above by
# hand, is the only robust way to source-grep for it). 0.static.sh uses
# this (not the regex) to confirm the training script's own source
# contains this literal text; the digits after it only exist at runtime
# (an f-string interpolation), so a source-code check can only look for
# the literal prefix, never the full pattern with its capture group.
TRAINING_RESUME_LOG_PREFIX='resuming from step'
