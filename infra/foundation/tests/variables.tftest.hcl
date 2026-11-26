# Input validation tests. They run `terraform plan` against a mocked AWS
# provider, so they need no credentials and create nothing:
#   terraform -chdir=infra/foundation test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

variables {
  name                         = "example-cell"
  region                       = "us-east-1"
  endpoint_public_access_cidrs = ["203.0.113.0/24"]
}

run "system_node_launch_template_tags_instances_and_volumes" {
  command = plan

  # Amazon EKS managed node group tags do not propagate to the node
  # group's own instances or volumes (Amazon EKS User Guide); this layer's
  # launch template tags both directly instead (eks.tf), so the budget
  # guardrail's (issue #95) cost_filter can see the system node group's
  # own spend, not only the fixed-cost resources default_tags reaches on
  # its own.
  variables {
    tags = { "distai-platform/cell" = "example-cell" }
  }

  assert {
    condition = length([
      for ts in aws_launch_template.system_node.tag_specifications :
      true if ts.resource_type == "instance" && lookup(ts.tags, "distai-platform/cell", null) == "example-cell"
    ]) == 1
    error_message = "the system node launch template must tag instances with distai-platform/cell = var.name."
  }

  assert {
    condition = length([
      for ts in aws_launch_template.system_node.tag_specifications :
      true if ts.resource_type == "volume" && lookup(ts.tags, "distai-platform/cell", null) == "example-cell"
    ]) == 1
    error_message = "the system node launch template must tag volumes with distai-platform/cell = var.name."
  }
}

run "argocd_accepts_all_three_roles" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings = [
        { role = "ADMIN", group_ids = ["admins"] },
        { role = "EDITOR", group_ids = ["team-a"] },
        { role = "VIEWER", group_ids = ["team-b", "team-c"] },
      ]
    }
  }
}

run "argocd_rejects_unknown_role" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings    = [{ role = "OWNER", group_ids = ["admins"] }]
    }
  }

  expect_failures = [var.argocd]
}

run "argocd_rejects_empty_group_ids" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings    = [{ role = "ADMIN", group_ids = [] }]
    }
  }

  expect_failures = [var.argocd]
}

run "argocd_rejects_duplicate_role" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings = [
        { role = "ADMIN", group_ids = ["admins"] },
        { role = "ADMIN", group_ids = ["more-admins"] },
      ]
    }
  }

  expect_failures = [var.argocd]
}

run "argocd_rejects_no_role_mappings" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings    = []
    }
  }

  expect_failures = [var.argocd]
}

run "endpoint_rejects_wide_cidrs" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/1", "128.0.0.0/1"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "endpoint_rejects_empty_list" {
  command = plan

  variables {
    endpoint_public_access_cidrs = []
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "system_node_group_rejects_graviton_instance_types" {
  command = plan

  variables {
    system_node_group = {
      instance_types = ["m7i.large", "m7g.large"]
    }
  }

  expect_failures = [var.system_node_group]
}

run "budget_limit_usd_null_creates_no_budget_resources" {
  command = plan

  variables {
    budget_limit_usd           = null
    budget_notification_emails = ["admin@example.com"]
  }

  assert {
    condition     = length(aws_budgets_budget.cell) == 0
    error_message = "budget_limit_usd = null must create no aws_budgets_budget."
  }

  assert {
    condition     = length(aws_sns_topic.budget_alerts) == 0
    error_message = "budget_limit_usd = null must create no aws_sns_topic."
  }

  assert {
    condition     = length(aws_sns_topic_policy.budget_alerts) == 0
    error_message = "budget_limit_usd = null must create no aws_sns_topic_policy."
  }

  # A non-empty budget_notification_emails must not matter when the feature
  # itself is off: the for_each gate, not just the count gate, must see null.
  assert {
    condition     = length(aws_sns_topic_subscription.budget_alert_email) == 0
    error_message = "budget_limit_usd = null must create no subscription even when budget_notification_emails is non-empty."
  }
}

run "budget_limit_usd_accepts_a_positive_amount" {
  command = plan

  variables {
    budget_limit_usd           = 10
    budget_notification_emails = ["admin@example.com"]
    tags                       = { "distai-platform/cell" = "example-cell" }
  }

  assert {
    condition     = length(aws_budgets_budget.cell) == 1
    error_message = "budget_limit_usd = 10 must create exactly one aws_budgets_budget."
  }

  assert {
    condition     = length(aws_sns_topic.budget_alerts) == 1
    error_message = "budget_limit_usd = 10 must create exactly one aws_sns_topic."
  }

  assert {
    condition     = length(aws_sns_topic_policy.budget_alerts) == 1
    error_message = "budget_limit_usd = 10 must create exactly one aws_sns_topic_policy granting budgets.amazonaws.com publish access."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.budget_alert_email) == 1
    error_message = "one address in budget_notification_emails must create exactly one subscription."
  }

  assert {
    condition     = aws_budgets_budget.cell[0].limit_amount == "10" && aws_budgets_budget.cell[0].limit_unit == "USD" && aws_budgets_budget.cell[0].time_unit == "MONTHLY"
    error_message = "the budget must track budget_limit_usd in USD, MONTHLY."
  }

  # Both notification blocks (80% and 100%, ACTUAL, GREATER_THAN, pointed at
  # this cell's own topic) must exist; cost_filter is a set of objects
  # (aws_budgets_budget's own schema), so its elements have no addressable
  # index -- a for expression with an if clause finds each one instead.
  # subscriber_sns_topic_arns is not asserted here: it depends on
  # aws_sns_topic.budget_alerts[0].arn, a computed value the mocked
  # provider leaves unknown at plan time (Terraform test's own "Unknown
  # condition value" error on a set-typed block when any element depends
  # on an unknown value), so only a real apply (issue #95 PR Test Results)
  # can confirm that link; the HCL below has only one place that sets
  # subscriber_sns_topic_arns per block, so there is nothing else it could
  # resolve to.
  assert {
    condition = length([
      for n in aws_budgets_budget.cell[0].notification :
      true if n.threshold == 80 && n.threshold_type == "PERCENTAGE" && n.notification_type == "ACTUAL" && n.comparison_operator == "GREATER_THAN"
    ]) == 1
    error_message = "the budget must have an 80% ACTUAL GREATER_THAN notification."
  }

  assert {
    condition = length([
      for n in aws_budgets_budget.cell[0].notification :
      true if n.threshold == 100 && n.threshold_type == "PERCENTAGE" && n.notification_type == "ACTUAL" && n.comparison_operator == "GREATER_THAN"
    ]) == 1
    error_message = "the budget must have a 100% ACTUAL GREATER_THAN notification."
  }

  # Regression check for a real bug an actual apply caught (issue #95 PR): an
  # HCL template literal for this value rendered the literal text
  # "${var.name}" instead of interpolating the cell name, because a literal
  # "$" immediately followed by "{" is HCL's own escape for a literal "${".
  assert {
    condition = length([
      for cf in aws_budgets_budget.cell[0].cost_filter :
      true if cf.name == "TagKeyValue" && contains(cf.values, "user:distai-platform/cell$example-cell")
    ]) == 1
    error_message = "cost_filter TagKeyValue must interpolate var.name after the literal \"user:distai-platform/cell$\" prefix, not render \"$${var.name}\" literally."
  }
}

run "budget_limit_usd_with_no_subscribers_still_creates_topic_and_budget" {
  command = plan

  # budget_notification_emails left at its default ([]): an admin may still
  # want the budget and its topic created, to add a subscriber from the
  # console later.
  variables {
    budget_limit_usd = 10
    tags             = { "distai-platform/cell" = "example-cell" }
  }

  assert {
    condition     = length(aws_budgets_budget.cell) == 1
    error_message = "budget_limit_usd = 10 must create exactly one aws_budgets_budget even with no subscribers."
  }

  assert {
    condition     = length(aws_sns_topic.budget_alerts) == 1
    error_message = "budget_limit_usd = 10 must create exactly one aws_sns_topic even with no subscribers."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.budget_alert_email) == 0
    error_message = "an empty budget_notification_emails must create zero subscriptions, not fail."
  }
}

run "budget_limit_usd_rejects_a_missing_cell_tag" {
  command = plan

  # var.tags here does not carry distai-platform/cell at all (the default
  # tags = {}): the precondition on aws_budgets_budget.cell must catch this
  # at plan time, since cost_filter would otherwise silently match nothing.
  variables {
    budget_limit_usd = 10
  }

  expect_failures = [aws_budgets_budget.cell[0]]
}

run "budget_limit_usd_rejects_a_cell_tag_mismatch" {
  command = plan

  # var.tags here does carry the key, but with a different cell's own name
  # as the value: the precondition must still catch this, not only the
  # key's absence.
  variables {
    budget_limit_usd = 10
    tags              = { "distai-platform/cell" = "some-other-cell" }
  }

  expect_failures = [aws_budgets_budget.cell[0]]
}

run "budget_limit_usd_rejects_zero" {
  command = plan

  variables {
    budget_limit_usd = 0
  }

  expect_failures = [var.budget_limit_usd]
}

run "budget_limit_usd_rejects_negative" {
  command = plan

  variables {
    budget_limit_usd = -5
  }

  expect_failures = [var.budget_limit_usd]
}

run "budget_notification_emails_rejects_malformed_address" {
  command = plan

  variables {
    budget_limit_usd           = 10
    budget_notification_emails = ["not-an-email"]
    tags                       = { "distai-platform/cell" = "example-cell" }
  }

  expect_failures = [var.budget_notification_emails]
}

run "budget_notification_emails_rejects_duplicates" {
  command = plan

  variables {
    budget_limit_usd           = 10
    budget_notification_emails = ["admin@example.com", "admin@example.com"]
    tags                       = { "distai-platform/cell" = "example-cell" }
  }

  expect_failures = [var.budget_notification_emails]
}
