output "provisioner_role_arn" {
  description = "Send this to Caytu. It is what the provisioning pipeline assumes."
  value       = aws_iam_role.provisioner.arn
}

output "external_id" {
  description = "Send this to Caytu over a private channel. Without it the role cannot be assumed."
  value       = local.external_id
  sensitive   = true
}

output "permissions_boundary_arn" {
  description = "Caytu passes this on every role it creates here. The apply is refused without it."
  value       = aws_iam_policy.boundary.arn
}

output "region" {
  description = "The one region this access is valid in."
  value       = var.region
}

output "what_to_send_caytu" {
  description = "Everything Caytu needs, in one place. The external id is printed separately."
  value = {
    account_id               = local.account_id
    region                   = var.region
    provisioner_role_arn     = aws_iam_role.provisioner.arn
    permissions_boundary_arn = aws_iam_policy.boundary.arn
    resource_prefix          = local.prefix
  }
}
