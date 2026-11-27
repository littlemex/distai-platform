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
#
# role_name/role_path default to this layer's own convention ("/" and
# "<cluster_name>-identity-<key>"); an entry importing an already-existing
# role sets both to that role's real values, because IAM role `name` and
# `path` are both ForceNew - a mismatch on either plans a replacement, not
# an update, defeating the import.

locals {
  # "<cluster_name>-identity-<key>" by default; an entry's own role_name
  # overrides it so an already-existing, hand-rolled role (whose real name
  # does not follow that convention) can be imported under its own name
  # without a replacement - IAM role names cannot be changed in place, so
  # the role's own `name` argument below must equal the already-existing
  # role's real name exactly for `terraform import` to plan an update
  # instead of a destroy-and-recreate.
  role_names = {
    for key, entry in var.platform_identities : key => coalesce(entry.role_name, "${var.cluster_name}-identity-${key}")
  }
}

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

  name               = local.role_names[each.key]
  path               = each.value.role_path
  description        = "distai-platform add-on identity (issue #8): ${each.key}, ${each.value.namespace}/${each.value.service_account}"
  assume_role_policy = data.aws_iam_policy_document.identity_assume[each.key].json
  # Policies attached/managed outside this layer (the migration case: a
  # hand-rolled role's own pre-existing attachments) must not block
  # DeleteRole with DeleteConflict when this layer's own apply removes
  # them via the exclusive resources below, nor when the whole root is
  # destroyed - force_detach_policies makes DeleteRole itself detach
  # everything first, which the exclusive resources' own destroy does not
  # reliably do on their own (per the provider's own documentation,
  # destroying an *_exclusive resource stops Terraform managing the set,
  # it does not necessarily detach it).
  force_detach_policies = true
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

  # One statement per declared s3 block, not one combined statement for
  # every bucket in the entry: a combined statement would put every
  # bucket's ARN in `resources` and every bucket's prefixes in one
  # `s3:prefix` condition, and IAM evaluates a statement's resource list
  # and its condition's value list independently (OR within each, not
  # paired) - an entry declaring bucket A with prefix "a/" and bucket B
  # with prefix "b/" would then also allow listing bucket A with prefix
  # "b/*" and bucket B with prefix "a/*", neither of which is declared.
  # One statement per s3 block keeps each bucket's own resource paired
  # with only that same block's own prefixes.
  dynamic "statement" {
    for_each = each.value.s3
    content {
      sid       = "AllowScopedS3List${statement.key}"
      actions   = ["s3:ListBucket"]
      resources = ["arn:${local.partition}:s3:::${statement.value.bucket}"]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = [for p in statement.value.prefixes : "${trimprefix(p, "/")}*"]
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

# --- Exclusive ownership of the role's managed and inline policies -------
#
# aws_iam_role_policy_attachment (a single declared attachment) and a
# plain aws_iam_role_policy (a single declared inline policy, by name)
# each manage only the one resource they declare: neither detaches a
# managed policy, nor removes an inline policy under a different name,
# that was attached outside this layer - exactly the shape a hand-rolled
# identity (issue #8's own Motivation) has, so an import would leave
# whatever was attached by hand still attached, contradicting the
# migration's own "tightened to this layer's declared shape" claim.
#
# aws_iam_role_policy_attachments_exclusive/aws_iam_role_policies_exclusive
# take over the role's *entire* set of managed attachments/inline policies
# instead: anything not in the given list is removed on the next apply.
# The provider's own documentation says that if a plain
# aws_iam_role_policy_attachment is *also* managed for the same role, its
# own policy ARN must be included in this resource's policy_arns to avoid
# drift; this layer never creates a plain attachment resource at all; the
# inline-policy exclusive resource must list every inline policy name
# this layer itself still manages (depends_on makes the content exist
# before this exclusive declaration is reconciled, even though the name
# list itself is computed only from var.platform_identities, not from
# that resource's own attributes).

resource "aws_iam_role_policy_attachments_exclusive" "entry" {
  for_each = var.platform_identities

  role_name   = aws_iam_role.entry[each.key].name
  policy_arns = each.value.policy_arns
}

resource "aws_iam_role_policies_exclusive" "entry" {
  for_each = var.platform_identities

  role_name    = aws_iam_role.entry[each.key].name
  policy_names = contains(keys(local.scoped_entries), each.key) ? ["scoped"] : []

  depends_on = [aws_iam_role_policy.identity_scoped]
}

# --- Pod Identity association: only this entry's own namespace+SA -------

resource "aws_eks_pod_identity_association" "entry" {
  for_each = var.platform_identities

  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.entry[each.key].arn
}
