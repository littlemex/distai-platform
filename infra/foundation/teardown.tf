# Teardown guards.
#
# Two things in the cell's VPC are created outside this state, and both block
# terraform destroy if they are still there when the network is removed:
#
#   - EC2 instances that Karpenter launches (Karpenter is installed by Argo
#     CD). Their network interfaces block the deletion of the subnets and of
#     the cluster security group, and removing the NAT gateway and routes
#     first cuts Karpenter off from AWS.
#   - Network interfaces that the VPC CNI creates (description aws-K8S-*) and
#     that stay behind, detached, when their node is terminated, and the
#     cluster security group that EKS creates and does not delete while such
#     an interface still references it. They block the deletion of the
#     subnets and of the VPC. They exist as soon as the cluster and its first
#     nodes do, whether or not the rest of the apply succeeded.
#
# Each is removed by its own destroy-time guard. A destroy-time provisioner
# runs only for a resource that is in the state and not tainted, so a guard
# protects exactly the resources that cannot exist without it: Terraform
# creates a resource only after everything it depends on.
#
#   terraform_data.teardown_guard (scripts/teardown-guard.sh) terminates the
#   Karpenter instances, waits until they are terminated, and deletes their
#   detached network interfaces, launch templates and instance profiles. It
#   needs the node role and the cluster, and it must run while the cluster,
#   the NAT gateway and the routes are still there, so it depends on all of
#   them and is created last. If an apply fails before it is created, Karpenter
#   was never installed, so there is nothing for it to do.
#
#   terraform_data.network_guard (scripts/network-guard.sh) terminates no
#   instance. It waits for the VPC CNI interfaces left in the VPC to settle,
#   deletes the detached ones, then deletes this cluster's EKS security group
#   (tag aws:eks:cluster-name = <name>). Its inputs are known once the VPC
#   exists, and the cluster depends on it, so it is in the state before the
#   cluster can exist: an apply that fails at any point after the cluster is
#   created still leaves it in place for terraform destroy.
#
# The two cannot be one resource. The instances are terminated before the
# cluster is destroyed, so that EKS deletes its own cluster security group
# (which every node uses) and no instance keeps billing while the control
# plane is deleted. The security group that EKS still leaves behind can only
# be removed after EKS has deleted the cluster. A single guard placed early
# (the cluster depending on it) would terminate the instances only after the
# cluster is gone; a single guard placed late is missing after a failed apply. The detached-interface cleanup is one
# function (scripts/guard-common.sh) that both call.
#
# Destroy order (Terraform destroys a resource before the resources it depends
# on):
#
#   1. aws_iam_role_policy_attachment.karpenter_controller depends on
#      teardown_guard, so it is destroyed first: Karpenter loses its
#      permissions and cannot launch replacements while the guard runs.
#   2. teardown_guard runs (if it is in the state).
#   3. The cluster, the node groups, the add-ons and everything else that
#      depends on the cluster are destroyed.
#   4. network_guard runs. The cluster depends on it, so it runs only after
#      the cluster is deleted; by then every node is terminated and nothing
#      in the VPC creates or attaches VPC CNI interfaces any more, so the
#      guard races with no one and only waits for the EC2 API to report the
#      final state of each interface. It refuses to remove anything while a
#      cluster with this name still exists.
#   5. network_guard depends on the subnets (and through them the VPC), so
#      they are destroyed only after it has finished.

resource "terraform_data" "teardown_guard" {
  input = {
    cluster_name   = aws_eks_cluster.this.name
    account_id     = local.account_id
    region         = var.region
    vpc_id         = aws_vpc.this.id
    node_role_name = aws_iam_role.karpenter_node.name
    script         = "${path.module}/scripts/teardown-guard.sh"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash \"$GUARD_SCRIPT\""

    environment = {
      GUARD_SCRIPT   = self.input.script
      CLUSTER_NAME   = self.input.cluster_name
      ACCOUNT_ID     = self.input.account_id
      AWS_REGION     = self.input.region
      VPC_ID         = self.input.vpc_id
      NODE_ROLE_NAME = self.input.node_role_name
    }
  }

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system,
    aws_ec2_tag.cluster_security_group_discovery,
    aws_eks_access_entry.karpenter_node,
    aws_iam_role_policy_attachment.karpenter_node,
    aws_subnet.private,
    aws_subnet.public,
    aws_route_table_association.private,
    aws_route_table_association.public,
    aws_route.private_nat,
    aws_route.public_internet,
    aws_nat_gateway.this,
    aws_eip.nat,
    aws_internet_gateway.this,
  ]
}

resource "terraform_data" "network_guard" {
  input = {
    cluster_name = var.name
    account_id   = local.account_id
    region       = var.region
    vpc_id       = aws_vpc.this.id
    script       = "${path.module}/scripts/network-guard.sh"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash \"$GUARD_SCRIPT\""

    environment = {
      GUARD_SCRIPT = self.input.script
      CLUSTER_NAME = self.input.cluster_name
      ACCOUNT_ID   = self.input.account_id
      AWS_REGION   = self.input.region
      VPC_ID       = self.input.vpc_id
    }
  }

  depends_on = [
    aws_subnet.private,
    aws_subnet.public,
  ]
}
