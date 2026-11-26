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
# default_tags); "user:" is required for a user-defined cost allocation tag
# (aws_budgets_budget's own TagKeyValue cost_filter documentation).
resource "aws_budgets_budget" "cell" {
  count = local.budget_enabled ? 1 : 0

  name         = "${var.name}-cell-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:distai-platform/cell$${var.name}"]
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
}
