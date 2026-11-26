output "cluster_name" {
  description = "EKS cluster name (equal to var.name)."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data of the cluster (public)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "region" {
  description = "AWS Region of the cell."
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, one per Availability Zone, tagged karpenter.sh/discovery = cluster name."
  value       = aws_subnet.private[*].id
}

output "node_security_group_id" {
  description = "Security group for nodes: the EKS cluster security group, tagged karpenter.sh/discovery = cluster name."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "karpenter_controller_role_arn" {
  description = "IAM role of the Karpenter controller, already associated with kube-system/karpenter through EKS Pod Identity."
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_name" {
  description = "IAM role name for nodes launched by Karpenter (EC2NodeClass spec.role); it has an EC2_LINUX access entry."
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name for Karpenter interruption handling (Helm value settings.interruptionQueue)."
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "argocd_capability_arn" {
  description = "ARN of the managed Argo CD capability, or null when var.argocd is not set."
  value       = try(aws_eks_capability.argocd[0].arn, null)
}

output "cluster_arn" {
  description = "ARN of the EKS cluster. The managed Argo CD capability's registration Secret needs this verbatim in its server field (an ARN, never an API server URL or kubernetes.default.svc)."
  value       = local.cluster_arn
}

output "budget_alert_topic_arn" {
  description = "ARN of the cell's Amazon SNS budget-alert topic, or null when var.budget_limit_usd is not set. An admin can subscribe more destinations to it from the console without any further Terraform apply."
  value       = try(aws_sns_topic.budget_alerts[0].arn, null)
}

output "budget_name" {
  description = "Name of the cell's aws_budgets_budget, or null when var.budget_limit_usd is not set."
  value       = try(aws_budgets_budget.cell[0].name, null)
}

output "argocd_namespace" {
  description = "Kubernetes namespace of the managed Argo CD capability's own objects (registration Secret, AppProject, root Application), or null when var.argocd is not set. No ApplicationSet or addon.yaml reads this directly; each generated Application *object* (control-plane bookkeeping: where Argo CD stores it) inherits that namespace from the root Application this output's consumer (gitops/bootstrap/bootstrap.sh) writes, but each add-on's own *workload* namespace (where its chart's pods and other resources actually land) is a separate namespace: key in that add-on's own addon.yaml, never this output."
  value       = try(aws_eks_capability.argocd[0].configuration[0].argo_cd[0].namespace, null)
}
