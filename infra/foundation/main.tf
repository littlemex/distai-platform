data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Regular Availability Zones only: Local Zones and Wavelength Zones are opt-in
# and are excluded.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  azs      = data.aws_availability_zones.available.names
  zone_ids = data.aws_availability_zones.available.zone_ids

  # Availability Zones in which the EKS control plane cannot place its network
  # interfaces (Amazon EKS User Guide, "Subnet requirements"). Subnets are still
  # created there, and Karpenter may launch nodes there; only the control plane
  # and the system node group avoid them.
  eks_unsupported_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]

  cluster_arn = "arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/${var.name}"
}
