# This layer takes the cell's own cluster_name/region as plain input
# variables, not a terraform_remote_state data source against
# infra/foundation's own state: a remote-state data source is read-only and
# would not make foundation itself plan, but it would still make every
# apply here read foundation's state file, coupling this layer's own
# availability to that file's continued existence and format - a dependency
# issue #8's own "adding or removing one entry plans and applies only
# infra/identities/" criterion is written to avoid, not only for the write
# side. The two string inputs below are the entire coupling.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  cluster_arn = "arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name}"
}
