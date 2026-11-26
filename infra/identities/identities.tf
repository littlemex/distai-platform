# Issue #8: one IAM role, and one EKS Pod Identity association, per
# declared entry of var.platform_identities - never one role shared across
# every entry. This is the same shape infra/foundation/karpenter.tf already
# uses for Karpenter's own controller role (its own trust policy, its own
# six scoped inline policies, its own Pod Identity association, bound to
# kube-system/karpenter and to no other ServiceAccount), formalized here as
# a reusable, declarative mechanism for every other platform add-on instead
# of a fifth hand-written copy. Karpenter's own role stays in
# infra/foundation untouched: it is not migrated here (its lifetime is the
# cell's own foundation lifetime, not an independently added/removed
# add-on), and this layer does not reproduce it.

# --- Trust policy: only this entry's own namespace+service_account -------
#
# Same shape as infra/foundation/karpenter.tf's own
# data.aws_iam_policy_document.karpenter_controller_assume: the three
# RequestTag conditions are the session tags EKS Pod Identity itself sets
# on every AssumeRole call it makes (no setup on this layer's side), so only
# a Pod Identity session for this exact cluster, namespace and service
# account can ever assume this entry's own role. This is what makes an
# undeclared workload's AccessDenied unconditional: it is not that some
# other policy happens to deny it, there is no role or association for it
# to reach in the first place.

data "aws_iam_policy_document" "identity_assume" {
  for_each = var.platform_identities

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [local.cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

resource "aws_iam_role" "entry" {
  for_each = var.platform_identities

  name               = "${var.cluster_name}-identity-${each.key}"
  description        = "distai-platform add-on identity (issue #8): ${each.key}, ${each.value.namespace}/${each.value.service_account}"
  assume_role_policy = data.aws_iam_policy_document.identity_assume[each.key].json
}

# --- Scoped inline policy: only this entry's own s3/kms_key_arns ---------
#
# Read (s3:GetObject, s3:ListBucket scoped by the s3:prefix condition) is
# unconditional once a bucket is declared; s3:PutObject/s3:DeleteObject are
# added only for a bucket entry with write = true - two different entries
# in the same map can therefore get read-only and read-write on different
# buckets, which one shared role's own policy document cannot express
# (issue #8's own Motivation): the document would need to grant the union
# of every associated workload's permissions, including write on a bucket
# only one of them should write to.

locals {
  # Object-level ARNs (one per bucket x prefix): GetObject and, for a write
  # entry, PutObject/DeleteObject are scoped to these, never to the bucket's
  # own ARN with no object key (that would mean "every object").
  s3_object_arns = {
    for key, entry in var.platform_identities : key => flatten([
      for b in entry.s3 : [
        for p in b.prefixes : "arn:${local.partition}:s3:::${b.bucket}/${trimprefix(p, "/")}*"
      ]
    ])
  }

  s3_write_object_arns = {
    for key, entry in var.platform_identities : key => flatten([
      for b in entry.s3 : b.write ? [
        for p in b.prefixes : "arn:${local.partition}:s3:::${b.bucket}/${trimprefix(p, "/")}*"
      ] : []
    ])
  }

  # Bucket-level ARNs (one per distinct bucket) for s3:ListBucket, with the
  # s3:prefix condition (below) doing the actual per-prefix scoping: S3 has
  # no object-level permission for ListBucket, only a bucket ARN with a
  # condition on the request's own prefix parameter.
  s3_bucket_arns = {
    for key, entry in var.platform_identities : key => distinct([
      for b in entry.s3 : "arn:${local.partition}:s3:::${b.bucket}"
    ])
  }

  s3_list_prefix_values = {
    for key, entry in var.platform_identities : key => flatten([
      for b in entry.s3 : [
        for p in b.prefixes : "${trimprefix(p, "/")}*"
      ]
    ])
  }

  any_s3_write = {
    for key, entry in var.platform_identities : key => anytrue([for b in entry.s3 : b.write])
  }

  # Only entries that declared s3 and/or kms_key_arns get this inline
  # policy at all: a policy document with zero statements is invalid, and
  # an entry with only policy_arns needs no inline policy of its own.
  scoped_entries = {
    for key, entry in var.platform_identities : key => entry
    if length(entry.s3) > 0 || length(entry.kms_key_arns) > 0
  }
}

data "aws_iam_policy_document" "identity_scoped" {
  for_each = local.scoped_entries

  dynamic "statement" {
    for_each = length(each.value.s3) > 0 ? [1] : []
    content {
      sid       = "AllowScopedS3Read"
      actions   = ["s3:GetObject"]
      resources = local.s3_object_arns[each.key]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.s3) > 0 ? [1] : []
    content {
      sid       = "AllowScopedS3List"
      actions   = ["s3:ListBucket"]
      resources = local.s3_bucket_arns[each.key]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = local.s3_list_prefix_values[each.key]
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.s3_write_object_arns[each.key]) > 0 ? [1] : []
    content {
      sid       = "AllowScopedS3Write"
      actions   = ["s3:PutObject", "s3:DeleteObject"]
      resources = local.s3_write_object_arns[each.key]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.kms_key_arns) > 0 ? [1] : []
    content {
      sid = "AllowScopedKms"
      actions = concat(
        ["kms:Decrypt"],
        local.any_s3_write[each.key] ? ["kms:GenerateDataKey"] : []
      )
      resources = each.value.kms_key_arns
    }
  }
}

resource "aws_iam_role_policy" "identity_scoped" {
  for_each = local.scoped_entries

  name   = "scoped"
  role   = aws_iam_role.entry[each.key].name
  policy = data.aws_iam_policy_document.identity_scoped[each.key].json
}

# --- Managed policy attachments: only this entry's own policy_arns -------

locals {
  policy_arn_pairs = merge([
    for key, entry in var.platform_identities : {
      for arn in entry.policy_arns : "${key}#${arn}" => {
        entry_key  = key
        policy_arn = arn
      }
    }
  ]...)
}

resource "aws_iam_role_policy_attachment" "entry_managed" {
  for_each = local.policy_arn_pairs

  role       = aws_iam_role.entry[each.value.entry_key].name
  policy_arn = each.value.policy_arn
}

# --- Pod Identity association: only this entry's own namespace+SA -------

resource "aws_eks_pod_identity_association" "entry" {
  for_each = var.platform_identities

  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.entry[each.key].arn
}
