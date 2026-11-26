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
  # FSx for Lustre's client ports (Amazon FSx for Lustre User Guide,
  # "Amazon VPC security groups for Lustre"): 988/tcp for the Lustre
  # protocol itself, 1021-1023/tcp and /udp for the lnet/LND transport.
  # Security groups are stateful (AWS EC2 User Guide, "Security group
  # rules"), so only the file system's own ingress (from every node, which
  # already shares one security group - eks.tf's cluster security group,
  # the same one Karpenter-launched nodes join) needs a rule here; FSx
  # never opens a new connection toward a client, so this security group
  # carries no egress rule at all (AWS's own default "allow all egress"
  # rule, present on every newly created security group unless removed,
  # is removed below for the same least-privilege reason
  # aws_default_security_group.this in vpc.tf empties the VPC's default
  # security group).
  fsx_lustre_ports = [
    { protocol = "tcp", from_port = 988, to_port = 988 },
    { protocol = "tcp", from_port = 1021, to_port = 1023 },
    { protocol = "udp", from_port = 1021, to_port = 1023 },
  ]
}

resource "aws_security_group" "fsx_lustre" {
  count = var.shared_fsx_lustre == null ? 0 : 1

  name        = "${var.name}-fsx-lustre"
  description = "Ingress for the shared FSx for Lustre file system (#18), from this cell own node/cluster security group only."
  vpc_id      = aws_vpc.this.id

  # Every newly created EC2 security group gets one default rule: allow
  # all IPv4 egress (EC2 User Guide, "Security group rules" - an API-level
  # default, not a Terraform artifact). Writing egress = [] here, rather
  # than omitting the argument, tells Terraform to manage the egress
  # rule set as a whole and removes that default rule on apply - FSx never
  # opens a connection toward a client (see local.fsx_lustre_ports's own
  # comment on why ingress alone is enough), so this file system's own
  # security group needs no egress at all, the same least-privilege
  # reasoning vpc.tf's aws_default_security_group.this already applies to
  # the VPC's default security group.
  egress = []

  tags = {
    Name = "${var.name}-fsx-lustre"
  }
}

resource "aws_security_group_rule" "fsx_lustre_ingress" {
  for_each = var.shared_fsx_lustre == null ? {} : { for p in local.fsx_lustre_ports : "${p.protocol}-${p.from_port}" => p }

  type                     = "ingress"
  security_group_id        = aws_security_group.fsx_lustre[0].id
  protocol                 = each.value.protocol
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  source_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description              = "FSx for Lustre client traffic from this cell own node/cluster security group"
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
  # the two together). Set unconditionally to true: this platform's own
  # test cells are destroyed and recreated (infra/foundation/README.md),
  # and a final backup left behind by a PERSISTENT cell's teardown would be
  # exactly the kind of untracked, billed leftover the real-machine
  # verification sweep (#18's own Test Results) exists to catch.
  skip_final_backup = true

  tags = {
    Name = "${var.name}-shared"
  }
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
