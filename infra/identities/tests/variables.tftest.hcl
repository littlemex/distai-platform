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
    condition     = length(aws_iam_role_policy_attachments_exclusive.entry["image-builder"].policy_arns) == 0
    error_message = "an entry with no policy_arns must declare an empty exclusive managed-policy set (removing anything attached outside this layer), not skip the exclusive resource."
  }

  assert {
    condition     = length(aws_iam_role_policies_exclusive.entry["image-builder"].policy_names) == 1 && contains(aws_iam_role_policies_exclusive.entry["image-builder"].policy_names, "scoped")
    error_message = "an entry that declares s3 must list exactly its own \"scoped\" inline policy in the exclusive inline-policy set."
  }

  assert {
    condition     = !contains(data.aws_iam_policy_document.identity_scoped["image-builder"].statement[*].sid, "AllowScopedS3Write")
    error_message = "a read-only entry (no s3 block sets write = true) must not get the write statement at all."
  }

  assert {
    condition     = !contains(flatten(data.aws_iam_policy_document.identity_scoped["image-builder"].statement[*].actions), "s3:PutObject") && !contains(flatten(data.aws_iam_policy_document.identity_scoped["image-builder"].statement[*].actions), "s3:DeleteObject")
    error_message = "a read-only entry's scoped policy must grant neither s3:PutObject nor s3:DeleteObject, under any statement."
  }

  assert {
    condition     = !contains(data.aws_iam_policy_document.identity_scoped["image-builder"].statement[*].sid, "AllowScopedKms")
    error_message = "an entry with no kms_key_arns declared must get no KMS statement at all."
  }

  assert {
    condition     = alltrue([for a in flatten(data.aws_iam_policy_document.identity_scoped["image-builder"].statement[*].actions) : a != "*" && a != "s3:*"])
    error_message = "no statement of a declared entry's scoped policy may grant a wildcard action."
  }

  assert {
    condition     = alltrue([for r in flatten(data.aws_iam_policy_document.identity_scoped["image-builder"].statement[*].resources) : r != "*"])
    error_message = "no statement of a declared entry's scoped policy may target a wildcard resource."
  }

  assert {
    condition = alltrue([
      for c in data.aws_iam_policy_document.identity_assume["image-builder"].statement[0].condition :
      c.variable != "aws:RequestTag/kubernetes-namespace" || (length(c.values) == 1 && contains(c.values, "image-builder"))
    ])
    error_message = "the trust policy's own namespace condition must scope to exactly this entry's declared namespace."
  }

  assert {
    condition = alltrue([
      for c in data.aws_iam_policy_document.identity_assume["image-builder"].statement[0].condition :
      c.variable != "aws:RequestTag/kubernetes-service-account" || (length(c.values) == 1 && contains(c.values, "image-builder"))
    ])
    error_message = "the trust policy's own service-account condition must scope to exactly this entry's declared service_account."
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
    condition     = contains(aws_iam_role_policy_attachments_exclusive.entry["mcp-server"].policy_arns, "arn:aws:iam::aws:policy/ReadOnlyAccess")
    error_message = "the declared policy_arns entry must be attached."
  }

  assert {
    condition     = length(aws_iam_role_policies_exclusive.entry["mcp-server"].policy_names) == 0
    error_message = "an entry with no s3/kms_key_arns must declare an empty exclusive inline-policy set (removing any inline policy attached outside this layer)."
  }
}

# Regression test: a single combined ListBucket statement, with every
# declared bucket's own ARN in `resources` and every declared bucket's own
# prefixes merged into one `s3:prefix` condition, would let IAM match any
# resource against any condition value independently - bucket A's own
# prefix would also be allowed when listing bucket B. One statement per
# declared s3 block (identities.tf) pairs each bucket with only its own
# prefixes.
run "multi_bucket_entry_list_statements_do_not_cross_pair" {
  command = plan

  variables {
    platform_identities = {
      multi-bucket = {
        namespace       = "kube-system"
        service_account = "multi-bucket"
        s3 = [
          { bucket = "distai-platform-bucket-a", prefixes = ["a-prefix/"] },
          { bucket = "distai-platform-bucket-b", prefixes = ["b-prefix/"] },
        ]
      }
    }
  }

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.identity_scoped["multi-bucket"].statement :
      s if s.actions == toset(["s3:ListBucket"])
    ]) == 2
    error_message = "a two-bucket entry must get two separate ListBucket statements, one per declared bucket."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.identity_scoped["multi-bucket"].statement : (
        s.actions != toset(["s3:ListBucket"]) || !(
          contains(s.resources, "arn:aws:s3:::distai-platform-bucket-a") &&
          contains(flatten([for c in s.condition : c.values]), "b-prefix/*")
        )
      )
    ])
    error_message = "bucket-a's own ListBucket statement must not also allow bucket-b's own declared prefix."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.identity_scoped["multi-bucket"].statement : (
        s.actions != toset(["s3:ListBucket"]) || !(
          contains(s.resources, "arn:aws:s3:::distai-platform-bucket-b") &&
          contains(flatten([for c in s.condition : c.values]), "a-prefix/*")
        )
      )
    ])
    error_message = "bucket-b's own ListBucket statement must not also allow bucket-a's own declared prefix."
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

run "role_name_override_lets_import_target_match_an_existing_role" {
  command = plan

  variables {
    platform_identities = {
      legacy-imagebuilder = {
        namespace       = "image-builder"
        service_account = "image-builder"
        role_name       = "example-cell-legacy-imagebuilder"
        s3 = [{
          bucket   = "distai-platform-images"
          prefixes = ["manifests/"]
        }]
      }
    }
  }

  assert {
    condition     = aws_iam_role.entry["legacy-imagebuilder"].name == "example-cell-legacy-imagebuilder"
    error_message = "an entry with role_name set must name its role exactly that value, not the derived <cluster_name>-identity-<key> default (the whole point: letting an already-existing role's real name be imported without a replacement)."
  }

  assert {
    condition     = aws_iam_role.entry["legacy-imagebuilder"].path == "/"
    error_message = "role_path must default to \"/\" when not set."
  }

  assert {
    condition     = aws_iam_role.entry["legacy-imagebuilder"].force_detach_policies == true
    error_message = "every entry's role must set force_detach_policies = true, so destroying this root never fails with DeleteConflict on a role whose policy_arns is non-empty (aws_iam_role_policy_attachments_exclusive's own destroy does not reliably detach on its own)."
  }
}

run "role_path_override_lets_import_target_a_non_default_path" {
  command = plan

  variables {
    platform_identities = {
      legacy-custom-path = {
        namespace       = "image-builder"
        service_account = "image-builder"
        role_name       = "example-cell-legacy-custom"
        role_path       = "/distai-platform/legacy/"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  assert {
    condition     = aws_iam_role.entry["legacy-custom-path"].path == "/distai-platform/legacy/"
    error_message = "role_path must be passed through to the role's own path, so importing a role created under a non-default path does not plan a replacement."
  }
}

run "rejects_invalid_role_path" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "kube-system"
        service_account = "x"
        role_path       = "no-leading-slash/"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_role_name_collision" {
  command = plan

  variables {
    platform_identities = {
      a = {
        namespace       = "kube-system"
        service_account = "a"
        role_name       = "example-cell-identity-b"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
      b = {
        namespace       = "kube-system"
        service_account = "b"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_two_entries_sharing_a_namespace_and_service_account" {
  command = plan

  variables {
    platform_identities = {
      a = {
        namespace       = "kube-system"
        service_account = "shared-sa"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
      b = {
        namespace       = "kube-system"
        service_account = "shared-sa"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  expect_failures = [var.platform_identities]
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

run "rejects_bare_slash_prefix" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "kube-system"
        service_account = "x"
        s3 = [{
          bucket   = "some-bucket"
          prefixes = ["/"]
        }]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "rejects_wildcard_in_prefix" {
  command = plan

  variables {
    platform_identities = {
      bad = {
        namespace       = "kube-system"
        service_account = "x"
        s3 = [{
          bucket   = "some-bucket"
          prefixes = ["a*b/"]
        }]
      }
    }
  }

  expect_failures = [var.platform_identities]
}

run "accepts_multi_region_kms_key" {
  command = plan

  variables {
    platform_identities = {
      ok = {
        namespace       = "kube-system"
        service_account = "x"
        kms_key_arns    = ["arn:aws:kms:us-east-1:111122223333:key/mrk-1234abcd1234abcd1234abcd1234abcd"]
      }
    }
  }

  assert {
    condition     = contains(data.aws_iam_policy_document.identity_scoped["ok"].statement[*].sid, "AllowScopedKms")
    error_message = "a multi-Region (mrk-prefixed) KMS key ARN must be accepted, not rejected as if it were an alias ARN."
  }
}

run "rejects_two_char_namespace_as_invalid" {
  command = plan

  variables {
    platform_identities = {
      ok = {
        namespace       = "ml"
        service_account = "x"
        policy_arns     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      }
    }
  }

  assert {
    condition     = aws_eks_pod_identity_association.entry["ok"].namespace == "ml"
    error_message = "a 2-character namespace (a valid Kubernetes label name) must be accepted, not rejected."
  }
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

  # cluster_name is a valid (<= 32 character) name on its own; the key
  # below is also valid (<= 39 characters) on its own. Only the combined
  # "<cluster_name>-identity-<key>" (32 + 10 + 30 = 72 here) exceeds IAM's
  # 64-character role-name limit, which is what this run checks.
  variables {
    cluster_name = "cell-xxxxxxxxxxxxxxxxxxxxxxxxxx1"
    platform_identities = {
      yyyyyyyyyyyyyyyyyyyyyyyyyyyyyy = {
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
