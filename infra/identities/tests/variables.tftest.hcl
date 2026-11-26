# Input validation tests. They run `terraform plan` against a mocked AWS
# provider, so they need no credentials and create nothing:
#   terraform -chdir=infra/identities test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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
  cluster_name = "example-cell"
  region       = "us-east-1"
}

run "empty_by_default_plans_clean" {
  command = plan

  assert {
    condition     = length(var.platform_identities) == 0
    error_message = "platform_identities must default to empty."
  }
}

run "one_read_only_s3_entry_plans" {
  command = plan

  variables {
    platform_identities = {
      image-builder = {
        namespace       = "image-builder"
        service_account = "image-builder"
        s3 = [{
          bucket   = "distai-platform-images"
          prefixes = ["manifests/"]
        }]
      }
    }
  }

  assert {
    condition     = aws_iam_role.entry["image-builder"].name == "example-cell-identity-image-builder"
    error_message = "the role name must be <cluster_name>-identity-<key>."
  }

  assert {
    condition     = aws_iam_role_policy.identity_scoped["image-builder"].role == aws_iam_role.entry["image-builder"].name
    error_message = "an entry that declares s3 must get the scoped inline policy, attached to its own role."
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.entry_managed) == 0
    error_message = "an entry with no policy_arns must get no managed policy attachment."
  }
}

run "write_entry_adds_put_delete_and_generatedatakey" {
  command = plan

  variables {
    platform_identities = {
      alb-controller = {
        namespace       = "kube-system"
        service_account = "aws-load-balancer-controller"
        s3 = [{
          bucket   = "distai-platform-alb-logs"
          prefixes = ["access-logs/"]
          write    = true
        }]
        kms_key_arns = ["arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"]
      }
    }
  }

  assert {
    condition     = contains(data.aws_iam_policy_document.identity_scoped["alb-controller"].statement[*].sid, "AllowScopedS3Write")
    error_message = "write = true on an s3 entry must add the write statement."
  }

  assert {
    condition     = contains(flatten(data.aws_iam_policy_document.identity_scoped["alb-controller"].statement[*].actions), "kms:GenerateDataKey")
    error_message = "a write entry with kms_key_arns declared must also grant kms:GenerateDataKey, not only kms:Decrypt."
  }
}

run "read_only_kms_entry_has_no_generatedatakey" {
  command = plan

  variables {
    platform_identities = {
      log-reader = {
        namespace       = "observability"
        service_account = "log-reader"
        s3 = [{
          bucket   = "distai-platform-alb-logs"
          prefixes = ["access-logs/"]
        }]
        kms_key_arns = ["arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"]
      }
    }
  }

  assert {
    condition     = !contains(flatten(data.aws_iam_policy_document.identity_scoped["log-reader"].statement[*].actions), "kms:GenerateDataKey")
    error_message = "a read-only entry (every s3 write = false) must not get kms:GenerateDataKey."
  }
}

run "policy_arns_only_entry_gets_no_inline_policy" {
  command = plan

  variables {
    platform_identities = {
      mcp-server = {
        namespace       = "mcp"
        service_account = "mcp-server"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_scoped) == 0
    error_message = "an entry with only policy_arns (no s3, no kms_key_arns) must get no inline policy, only the managed-policy attachment."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.entry_managed["mcp-server#arn:aws:iam::aws:policy/ReadOnlyAccess"].policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "the declared policy_arns entry must be attached."
  }
}

run "two_entries_get_two_independent_roles_and_associations" {
  # apply, not plan: role_arn and the role_arns output are both computed
  # attributes of a mocked resource, unknown until "applied" even against
  # mock_provider (no real AWS call either way - mock_provider replaces
  # the provider's RPCs entirely, so this creates nothing real).
  #
  # Two override_resource blocks give each entry's mocked role a distinct,
  # well-formed ARN: mock_provider's own default mocked value for a
  # computed string attribute is an opaque placeholder, not ARN-shaped,
  # and aws_eks_pod_identity_association.role_arn has an ARN-format
  # validator in the provider's own schema that runs even against a
  # mocked apply, so the un-overridden default fails validation (not a
  # real AWS call - purely the provider's own, schema-level check).
  command = apply

  override_resource {
    target = aws_iam_role.entry["image-builder"]
    values = {
      arn = "arn:aws:iam::111122223333:role/example-cell-identity-image-builder"
    }
  }

  override_resource {
    target = aws_iam_role.entry["openzfs"]
    values = {
      arn = "arn:aws:iam::111122223333:role/example-cell-identity-openzfs"
    }
  }

  variables {
    platform_identities = {
      image-builder = {
        namespace       = "image-builder"
        service_account = "image-builder"
        s3 = [{
          bucket   = "distai-platform-images"
          prefixes = ["manifests/"]
        }]
      }
      openzfs = {
        namespace       = "openzfs"
        service_account = "openzfs-csi"
        policy_arns     = ["arn:aws:iam::aws:policy/AmazonFSxFullAccess"]
      }
    }
  }

  assert {
    condition     = length(aws_iam_role.entry) == 2
    error_message = "two declared entries must create two roles."
  }

  assert {
    condition     = aws_eks_pod_identity_association.entry["image-builder"].role_arn != aws_eks_pod_identity_association.entry["openzfs"].role_arn
    error_message = "two entries must never share one role's ARN."
  }

  assert {
    condition     = output.role_arns["image-builder"] != output.role_arns["openzfs"]
    error_message = "role_arns output must expose one distinct ARN per entry."
  }
}

run "rejects_entry_with_no_grant_at_all" {
  command = plan

  variables {
    platform_identities = {
      empty = {
        namespace       = "kube-system"
        service_account = "empty"
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_uppercase_key" {
  command = plan

  variables {
    platform_identities = {
      Bad-Key = {
        namespace       = "kube-system"
        service_account = "x"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_empty_prefixes_list" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "kube-system"
        service_account = "x"
        s3 = [{
          bucket   = "some-bucket"
          prefixes = []
        }]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_invalid_bucket_name" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "kube-system"
        service_account = "x"
        s3 = [{
          bucket   = "Not_A_Valid_Bucket"
          prefixes = [""]
        }]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_kms_alias_arn" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "kube-system"
        service_account = "x"
        kms_key_arns    = ["arn:aws:kms:us-east-1:111122223333:alias/my-alias"]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_non_iam_policy_arn" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "kube-system"
        service_account = "x"
        policy_arns     = ["arn:aws:s3:::not-a-policy-arn"]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_invalid_namespace" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "Not_Valid"
        service_account = "x"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_role_name_over_64_chars" {
  command = plan

  variables {
    cluster_name = "a-very-long-cluster-name-near-the-limit-ok"
    platform_identities = {
      an-unreasonably-long-add-on-identity-key-name = {
        namespace       = "kube-system"
        service_account = "x"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_invalid_cluster_name" {
  command = plan

  variables {
    cluster_name = "Not Valid!"
  }

  expect_failures = [var.cluster_name]
}

run "rejects_invalid_region" {
  command = plan

  variables {
    region = "not-a-region"
  }

  expect_failures = [var.region]
}
