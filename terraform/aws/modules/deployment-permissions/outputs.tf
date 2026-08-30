output "policy_json" {
  description = "The permission set, ready to attach to a role."
  value       = data.aws_iam_policy_document.provisioner.json
}

output "cluster_policy_json" {
  description = "The extra permissions an EKS cluster needs. Its own policy because both together exceed the 6,144 character limit on one."
  value       = data.aws_iam_policy_document.cluster.json
}
