# Per-cell cost guardrail (issue #95). Everything here is created only when a
# cell declares var.budget_limit_usd; the default (null) creates nothing, the
# same shape var.argocd already uses for a declared, opt-in target.
#
# AWS Cost Anomaly Detection is deliberately not here: it has no per-cell
# cost_filter equivalent to aws_budgets_budget's own and is naturally
# account-wide, while this layer's own tests/1.e2e.sh creates and destroys a
# cell on every run. An account-wide Monitor is a separate RFC (issue #95
# comment), decided once issue #41's delivery tiers settle who owns an
# account-wide, cell-independent resource.
#
# Scope limit (issue #95 comment, tracked as issue #98): this cost_filter
# matches only resources this layer's own Terraform creates (every one
# already carries the distai-platform/cell tag through var.tags and the
# provider's default_tags - the precondition below enforces that). It does
# not yet match EC2 instances Karpenter launches into a capacity-pool
# (gitops/charts/capacity-pool's EC2NodeClass sets no spec.tags), which is
# the Issue's own two accident scenarios and the larger, more variable share
# of a cell's spend. Closing that needs a chart-level change with its own
# real-machine verification on a cluster with Karpenter actually running,
# outside this layer's own Terraform and this PR's real-machine budget.

locals {
  budget_enabled = var.budget_limit_usd != null
}

# One SNS topic per cell, the destination for both notification thresholds
# below. Kept separate from aws_budgets_budget's own subscriber_email_addresses
# argument so a subscriber can be added or removed later (console or another
# apply of this same variable) without touching the budget resource, following
# the same "one AWS API destination per cell, owned by this layer" shape as
# aws_sqs_queue.karpenter_interruption.
resource "aws_sns_topic" "budget_alerts" {
  count = local.budget_enabled ? 1 : 0

  name = "${var.name}-budget-alerts"
}

# AWS Budgets does not get implicit permission to publish to a topic it did
# not create, even one in the same account: without this policy, apply still
# succeeds and the budget still reaches HEALTHY, but no notification is ever
# delivered (AWS's own Budgets-to-SNS setup documentation; confirmed this
# platform's own real apply never exercises delivery, since neither
# describe-budget nor get-topic-attributes calls it).
resource "aws_sns_topic_policy" "budget_alerts" {
  count = local.budget_enabled ? 1 : 0

  arn = aws_sns_topic.budget_alerts[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AWSBudgetsSNSPublishingPermissions"
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.budget_alerts[0].arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:budgets::${local.account_id}:*" }
      }
    }]
  })
}

# Each address needs its own AWS-sent confirmation click before it receives
# anything; an empty var.budget_notification_emails still creates the topic
# and the budget, just with nobody subscribed yet.
resource "aws_sns_topic_subscription" "budget_alert_email" {
  for_each = local.budget_enabled ? toset(var.budget_notification_emails) : toset([])

  topic_arn = aws_sns_topic.budget_alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

# MONTHLY COST budget scoped to this one cell's own tagged resources. The
# cost_filter uses the tag key every resource this layer creates already
# carries (infra/foundation/terraform.tfvars.example: tags =
# { "distai-platform/cell" = "<name>" }, applied through the provider's
# default_tags); "user:" and the "$" between the tag key and its value are
# both AWS's own TagKeyValue format (aws_budgets_budget's own cost_filter
# documentation), not HCL interpolation syntax. format(), not a quoted
# "...cell$${var.name}" template literal, builds this value: HCL's own escape
# rule for a literal "$" immediately followed by "{" consumes the brace too,
# so that literal rendered the literal text "${var.name}" instead of the
# cell name on a real apply (issue #95 PR) before this fix.
resource "aws_budgets_budget" "cell" {
  count = local.budget_enabled ? 1 : 0

  name         = "${var.name}-cell-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:distai-platform/cell$%s", var.name)]
  }

  # ACTUAL, not FORECASTED: a forecast-based threshold needs a full billing
  # period of history this layer's own short-lived test cells never
  # accumulate.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts[0].arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts[0].arn]
  }

  # The cost_filter above assumes var.tags actually carries this cell's own
  # distai-platform/cell tag; without it the budget still creates and still
  # reaches HEALTHY, but cost_filter matches nothing and the budget tracks
  # $0 forever regardless of real spend. Caught at plan time, not after a
  # month of silent non-coverage.
  lifecycle {
    precondition {
      condition     = lookup(var.tags, "distai-platform/cell", null) == var.name
      error_message = "var.tags must set \"distai-platform/cell\" = var.name whenever budget_limit_usd is set, or cost_filter matches nothing (see infra/foundation/terraform.tfvars.example)."
    }
  }
}
