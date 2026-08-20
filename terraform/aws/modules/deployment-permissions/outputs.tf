output "policy_json" {
  description = "The permission set, ready to attach to a role."
  value       = data.aws_iam_policy_document.provisioner.json
}
