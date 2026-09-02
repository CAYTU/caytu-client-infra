output "provisioning_role_arn" {
  description = "Set as the AWS_PROVISIONING_ROLE_ARN variable on the repository."
  value       = aws_iam_role.provisioning.arn
}

output "agent_publish_role_arn" {
  description = "Set as the AWS_AGENT_PUBLISH_ROLE_ARN variable on the repository."
  value       = aws_iam_role.agent_publish.arn
}

output "template_publish_role_arn" {
  description = "Set as the AWS_TEMPLATE_PUBLISH_ROLE_ARN variable on the repository."
  value       = aws_iam_role.template_publish.arn
}

output "ci_access_role_arn" {
  description = "Set as the AWS_CI_ACCESS_ROLE_ARN variable on the repository."
  value       = aws_iam_role.ci_access.arn
}
