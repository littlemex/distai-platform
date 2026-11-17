# Teardown guard.
#
# Karpenter is installed by Argo CD, so the instances it launches are not in
# this state. If they are still running when the network is destroyed, their
# network interfaces block the deletion of the subnets and of the cluster
# security group, and removing the NAT gateway and routes first cuts Karpenter
# off from AWS. This resource does nothing on create; on destroy it runs
# scripts/teardown-guard.sh, which terminates every instance Karpenter launched
# for this cluster, waits until they are terminated, and then removes what
# those instances leave behind (detached VPC CNI network interfaces, launch
# templates, instance profiles).
#
# Destroy order (Terraform destroys a resource before the resources it depends
# on):
#
#   1. aws_iam_role_policy_attachment.karpenter_controller depends on this
#      guard, so it is destroyed first: Karpenter loses its permissions and
#      cannot launch replacements while the guard runs.
#   2. This guard runs.
#   3. The guard depends on the cluster, the node role and every network
#      resource, so all of them are destroyed only after it has finished.

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
