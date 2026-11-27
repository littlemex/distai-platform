output "role_arns" {
  description = "Map from platform_identities key to that entry's own IAM role ARN."
  value       = { for key, role in aws_iam_role.entry : key => role.arn }
}

output "role_names" {
  description = "Map from platform_identities key to that entry's own IAM role name."
  value       = { for key, role in aws_iam_role.entry : key => role.name }
}
