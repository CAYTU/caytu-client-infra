output "provisioning_role_arn" {
  description = "Set as the AWS_PROVISIONING_ROLE_ARN variable on the repository."
  value       = aws_iam_role.provisioning.arn
}

output "agent_publish_role_arn" {
  description = "Set as the AWS_AGENT_PUBLISH_ROLE_ARN variable on the repository."
  value       = aws_iam_role.agent_publish.arn
}
