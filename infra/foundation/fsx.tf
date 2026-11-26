# Optional shared FSx for Lustre file system (#18, #22 Decision 8), created
# only when var.shared_fsx_lustre is set. This is the "Terraform (cell-shell)
# resource that no Issue in this batch creates yet" #18 and #17's own
# "Terraform creates" table both named: the file system itself, the
# aws-fsx-csi-driver managed add-on that mounts it, and the one private
# container registry this cell needs because sharedfs (the controller that
# turns this one file system into per-team directories, gitops/addon-catalog/
# sharedfs) ships no image or chart of its own (#18's own Facts checked,
# 2026-11-26: no tag, no release, no image-publishing workflow at the pinned
# commit). Everything past this file is gitops/'s: the static PersistentVolume,
# its reserving PVC and the FilesystemShare objects are Kubernetes objects,
# never Terraform state (gitops/README.md's own rule), and read this layer's
# outputs below through the cell-registration Secret's annotations
# (gitops/bootstrap/bootstrap.sh), the same mechanism optional-pool's
# clusterName/nodeRole and capacity-pool's nodeRole already use - never a
# literal value in a committed gitops/ file, since the ECR repository URL
# below contains this account's ID.

locals {
  # FSx for Lustre's own ports (AWS FSx for Lustre User Guide, "File
  # system access control with Amazon VPC" -> "Amazon VPC Security
  # Groups", fetched 2026-11-26): TCP 988 for the Lustre protocol itself,
  # TCP 1018-1023 for the LNET/LND transport. That same page's own
  # required-rules table is explicit that this is not ingress-from-clients
  # alone: the file system's own security group needs self-referencing
  # ingress and ingress from the client security group - the file
  # system's own network interfaces talk to each other over these same
  # ports, not only to a mounting client, and CreateFileSystem's own
  # server-side validation enforces this (confirmed on the runner,
  # 2026-11-26: a security group with ingress from the client security
  # group only, no self-reference, failed CreateFileSystem outright with
  # "InvalidNetworkSettings: ... does not permit Lustre LNET network
  # traffic on port 988" - security groups being stateful was not enough
  # to satisfy this check, since the self-referencing rules this
  # validation wants are a different, and genuinely missing, pair of
  # rules, not a question of return traffic). That same table also lists
  # self-referencing and to-client egress as required; both are strict
  # subsets of "all traffic to anywhere", already covered by the default
  # allow-all-egress rule every new EC2 security group gets (EC2 User
  # Guide, "Security group rules") - see aws_security_group.fsx_lustre's
  # own comment on why this file manages ingress only, not egress.
  fsx_lustre_ports = [
    { protocol = "tcp", from_port = 988, to_port = 988 },
    { protocol = "tcp", from_port = 1018, to_port = 1023 },
  ]
}

resource "aws_security_group" "fsx_lustre" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  name        = "${var.name}-fsx-lustre"
  description = "Lustre traffic for the shared FSx for Lustre file system (#18): self-referencing and from this cell own node/cluster security group (ingress); the default allow-all egress covers both return paths this group needs."
  vpc_id      = aws_vpc.this.id

  # No egress argument here at all, not even egress = []. AWS's own
  # required-rules table (this file's own header comment above) also
  # lists self-referencing egress and egress to the client security
  # group as required, but both are strict subsets of "all traffic to
  # anywhere" - the default allow-all-IPv4-egress rule every new EC2
  # security group gets already satisfies them, so no narrower egress
  # rule is needed to reach that requirement. Writing egress = [] to
  # manage the rule set down to only two narrower rules was tried first
  # and reverted: it tells Terraform's AWS provider the security group's
  # egress rules are fully described by this resource's own egress
  # argument (zero of them), while two separate aws_security_group_rule
  # egress resources also claimed ownership of specific egress rules on
  # the same security group - mixing a security group's own inline
  # egress attribute (even an explicit empty list) with separate
  # aws_security_group_rule resources for the same group is the AWS
  # provider's own documented anti-pattern ("we recommend using one or
  # the other, never both"), and produced a perpetual plan diff on the
  # runner. Dropping the egress argument and those two rule resources
  # entirely removes the conflict and the extra resources together,
  # since the default already covers what they were for.
  tags = {
    Name = "${var.name}-fsx-lustre"
  }
}

locals {
  fsx_lustre_port_map = { for p in local.fsx_lustre_ports : "${p.protocol}-${p.from_port}" => p }
}

# Self-referencing ingress: the file system's own network interfaces talk
# to each other over these ports (AWS's own required-rules table, this
# file's own header comment above). Egress is not managed here - see
# aws_security_group.fsx_lustre's own comment on why.
resource "aws_security_group_rule" "fsx_lustre_self_ingress" {
  for_each = var.shared_fsx_lustre == null ? {} : local.fsx_lustre_port_map

  type                     = "ingress"
  security_group_id        = aws_security_group.fsx_lustre[0].id
  protocol                 = each.value.protocol
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  source_security_group_id = aws_security_group.fsx_lustre[0].id
  description              = "FSx for Lustre file servers to each other (self-referencing, required by CreateFileSystem)"
}

# Client traffic: this cell's node/cluster security group (every
# Karpenter-launched node and the system node group share it, eks.tf).
# Ingress only - the return path and this group's own egress to the
# client security group are both covered by the default allow-all egress
# rule (see aws_security_group.fsx_lustre's own comment).
resource "aws_security_group_rule" "fsx_lustre_client_ingress" {
  for_each = var.shared_fsx_lustre == null ? {} : local.fsx_lustre_port_map

  type                     = "ingress"
  security_group_id        = aws_security_group.fsx_lustre[0].id
  protocol                 = each.value.protocol
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  source_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description              = "FSx for Lustre client traffic from this cell own node-cluster security group"
}

# The matching half on the client side: AWS's own required-rules table
# names this as its own rule, not something the ingress rule above and
# plain TCP statefulness already cover between them - a Lustre mount is
# initiated by the client, but the file system's own servers also open
# connections back for some of the LNET traffic, which the client side's
# security group must itself allow as ingress, not only rely on being the
# stateful return path of a connection it opened (the whole reason AWS's
# table lists this as a fourth, separate rule rather than three). Added
# directly to the cluster security group (every Karpenter-launched node
# and the system node group's own shared security group, eks.tf) rather
# than to that security group's own inline rule set, the same technique
# fsx_lustre_client_ingress above and argocd.tf's own documented resource
# pair already use: a separate aws_security_group_rule only adds a rule,
# it does not take over managing the whole group EKS itself created.
resource "aws_security_group_rule" "cluster_fsx_lustre_ingress" {
  for_each = var.shared_fsx_lustre == null ? {} : local.fsx_lustre_port_map

  type                     = "ingress"
  security_group_id        = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  protocol                 = each.value.protocol
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  source_security_group_id = aws_security_group.fsx_lustre[0].id
  description              = "FSx for Lustre traffic from the shared file system's own security group (#18)"
}

resource "aws_fsx_lustre_file_system" "shared" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  storage_capacity            = var.shared_fsx_lustre.storage_capacity_gib
  subnet_ids                  = [aws_subnet.private[0].id]
  security_group_ids          = [aws_security_group.fsx_lustre[0].id]
  deployment_type             = var.shared_fsx_lustre.deployment_type
  per_unit_storage_throughput = var.shared_fsx_lustre.per_unit_storage_throughput

  # PERSISTENT_1/PERSISTENT_2 take a final backup on deletion unless this is
  # set; SCRATCH_1/SCRATCH_2 do not support backups at all, and the FSx API
  # ignores this argument for those deployment types (confirmed against the
  # aws_fsx_lustre_file_system resource schema - the argument is accepted
  # regardless of deployment_type, with no provider-side validation tying
  # the two together). Sourced from the variable (default false, AWS's own
  # CreateFileSystem default), not hardcoded true here: see
  # var.shared_fsx_lustre's own skip_final_backup field description for why
  # the safe default is kept for every cell except the ones that opt out of
  # it explicitly (this platform's own disposable test fixtures do).
  skip_final_backup = var.shared_fsx_lustre.skip_final_backup

  tags = {
    Name = "${var.name}-shared"
  }

  # Explicit depends_on, even though no argument above references either
  # of these two rules directly (only aws_security_group.fsx_lustre[0].id,
  # the group itself, which exists before any of its own rules do): with
  # no attribute in common, Terraform's graph has no edge forcing the
  # rules to attach before CreateFileSystem fires, so it schedules the two
  # concurrently - a CreateFileSystem that wins the race sees a security
  # group with no Lustre rules yet. Reproduced twice on the runner,
  # 2026-11-26: attempt 2 (CreateFileSystem happened to run after the
  # rules attached) succeeded; attempt 3, same code, failed with the
  # identical "does not permit Lustre LNET network traffic on port 988"
  # this file's own security-group comment already names - the same
  # shape of gap argocd.tf's own aws_eks_access_policy_association.argocd
  # documents and fixes the same way.
  depends_on = [
    aws_security_group_rule.fsx_lustre_self_ingress,
    aws_security_group_rule.fsx_lustre_client_ingress,
  ]
}

output "shared_fsx_lustre_file_system_id" {
  description = "ID of the shared FSx for Lustre file system, or null when var.shared_fsx_lustre is not set. Consumed by gitops/charts/sharedfs-shares through the cell-registration Secret's distai.dev.annotations/sharedfs-fsx-file-system-id annotation (gitops/bootstrap/bootstrap.sh), never committed as a literal value."
  value       = try(aws_fsx_lustre_file_system.shared[0].id, null)
}

output "shared_fsx_lustre_dns_name" {
  description = "DNS name of the shared FSx for Lustre file system, or null when unset. See shared_fsx_lustre_file_system_id's own description for how this reaches gitops/."
  value       = try(aws_fsx_lustre_file_system.shared[0].dns_name, null)
}

output "shared_fsx_lustre_mount_name" {
  description = "Mount name of the shared FSx for Lustre file system, or null when unset. See shared_fsx_lustre_file_system_id's own description for how this reaches gitops/."
  value       = try(aws_fsx_lustre_file_system.shared[0].mount_name, null)
}

output "shared_fsx_lustre_storage_capacity_gib" {
  description = "Storage capacity (GiB) of the shared FSx for Lustre file system, or null when unset. gitops/charts/sharedfs-shares' own static PersistentVolume sets spec.capacity.storage to this value, so the two never drift."
  value       = try(var.shared_fsx_lustre.storage_capacity_gib, null)
}

# --- aws-fsx-csi-driver (static provisioning only) ---------------------------
#
# This cell never uses dynamic FSx provisioning (gitops/charts/sharedfs-shares
# renders one static PersistentVolume; sharedfs's own controller holds no AWS
# credentials at all - its README, "The controller needs no cloud
# credentials"). The driver's own documented example policy
# (kubernetes-sigs/aws-fsx-csi-driver, docs/install.md) grants
# fsx:CreateFileSystem/DeleteFileSystem/UpdateFileSystem plus IAM
# service-linked-role actions for the dynamic, S3-Data-Repository-Association
# path this platform does not take; granting it here would be a broader IAM
# policy than this component ever calls, for a path this platform has no
# mechanism to reach (nothing renders a StorageClass with
# provisioner: fsx.csi.aws.com). The one read action kept
# (fsx:DescribeFileSystems) is scoped to this one file system's own ARN, not
# every file system in the account, matching the least-privilege pattern
# AGENTS.md section 6 already states for every IAM role in this layer.
locals {
  fsx_csi_driver_namespace       = "kube-system"
  fsx_csi_driver_service_account = "fsx-csi-controller-sa"
}

data "aws_iam_policy_document" "fsx_csi_driver_assume" {
  count = var.shared_fsx_lustre == null ? 0 : 1

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
      values   = [local.fsx_csi_driver_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.fsx_csi_driver_service_account]
    }
  }
}

data "aws_iam_policy_document" "fsx_csi_driver" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  statement {
    actions   = ["fsx:DescribeFileSystems"]
    resources = ["arn:${local.partition}:fsx:${var.region}:${local.account_id}:file-system/${aws_fsx_lustre_file_system.shared[0].id}"]
  }
}

resource "aws_iam_role" "fsx_csi_driver" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  name               = "${var.name}-fsx-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.fsx_csi_driver_assume[0].json
}

resource "aws_iam_role_policy" "fsx_csi_driver" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  name   = "fsx-describe-only"
  role   = aws_iam_role.fsx_csi_driver[0].name
  policy = data.aws_iam_policy_document.fsx_csi_driver[0].json
}

resource "aws_eks_addon" "fsx_csi_driver" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-fsx-csi-driver"
  addon_version               = local.addon_versions[var.kubernetes_version]["aws-fsx-csi-driver"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    service_account = local.fsx_csi_driver_service_account
    role_arn        = aws_iam_role.fsx_csi_driver[0].arn
  }

  depends_on = [
    aws_eks_node_group.system,
    aws_iam_role_policy.fsx_csi_driver,
  ]
}

# --- Container registry for the sharedfs controller image -------------------
#
# sharedfs (gitops/addon-catalog/sharedfs) ships no image of its own (#18's
# own Facts checked, 2026-11-26). This is the "container registry" #17's own
# "Terraform creates" table already named as a cell-shell resource; this is
# the first component this platform has needed it for. One repository per
# cell, not a platform-wide one: a shared, account-wide registry would be a
# second kind of "platform-wide" resource this layer's own design deliberately
# avoids (every other add-on's image comes from an upstream public registry -
# gitops/README.md's own Versioning section - so there has never been a
# second consumer to generalize for; splitting this into its own variable
# once one exists is a later PR's call, not a guess made here).
resource "aws_ecr_repository" "sharedfs_controller" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  name = "${var.name}-sharedfs-controller"
  # force_delete = true: this platform's own cells are destroyed and
  # recreated by design (infra/foundation/README.md), and ECR's own
  # default refuses DeleteRepository outright while any image remains
  # inside it ("RepositoryNotEmptyException") - every real-machine run
  # that reaches gitops/bootstrap/sharedfs-image-publish.sh pushes at
  # least one image here, so without this, `terraform destroy` on any
  # such run would fail at this one resource and leave a real, billed
  # repository behind for the next real-machine sweep to catch instead of
  # this run's own teardown. The same reasoning as skip_final_backup
  # above: a disposable fixture's own teardown should not depend on a
  # human remembering to empty a registry by hand first.
  force_delete = true
  # MUTABLE, not IMMUTABLE: every consumer of this image (the sharedfs
  # addon-catalog entry's own cell marker, through
  # distai.dev.annotations/sharedfs-controller-image) addresses it by
  # digest, never by tag, so tag mutability has no effect on correctness
  # here - only on whether gitops/bootstrap/sharedfs-image-publish.sh can
  # re-run against the same tag (ko's own default push, with --bare and no
  # --tags) more than once. IMMUTABLE would reject that second push
  # outright.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # AES256 (ECR's own managed encryption), not aws_kms_key.secrets: a
  # customer-managed KMS key would need kms:Decrypt/GenerateDataKey*/
  # DescribeKey granted to every principal that ever pulls this image -
  # every node's own role (system_node, the Karpenter node role), not only
  # the publisher - and neither role carries any KMS statement today (only
  # the EKS cluster role and the Pod Identity roles this file itself
  # creates do). Reusing aws_kms_key.secrets without also widening those
  # node roles would make every pull fail closed with AccessDenied on
  # Decrypt; AES256 needs no such grant at all and is AWS's own documented
  # default for a repository with no specific confidentiality need beyond
  # what it already provides.
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.name}-sharedfs-controller"
  }
}

output "sharedfs_controller_ecr_repository_url" {
  description = "Repository URL for the self-published sharedfs controller image, or null when var.shared_fsx_lustre is not set. gitops/bootstrap/sharedfs-image-publish.sh pushes to this repository and records the resulting image@digest on the cell-registration Secret's own annotation - never this URL alone, and never as a literal value in any committed gitops/ file (it contains this account's ID)."
  value       = try(aws_ecr_repository.sharedfs_controller[0].repository_url, null)
}
