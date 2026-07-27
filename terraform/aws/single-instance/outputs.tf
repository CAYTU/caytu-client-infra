# The CLI reads these outputs via `terraform output -json` and writes them into
# .caytu-client-state.json + .env.aws-single. Keep names stable — the CLI
# parses them by name.

output "public_ip" {
  description = "Elastic IP attached to the instance"
  value       = aws_eip.this.public_ip
}

output "instance_id" {
  description = "EC2 instance id"
  value       = aws_instance.this.id
}

output "instance_type" {
  description = "EC2 instance type"
  value       = aws_instance.this.instance_type
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "security_group_id" {
  description = "Security group id (used by 'caytu-client aws allow-me')"
  value       = aws_security_group.this.id
}

output "key_name" {
  description = "AWS key pair name"
  value       = aws_key_pair.this.key_name
}

output "ssh_key_path" {
  description = "Local path to the generated SSH private key (empty if operator supplied ssh_public_key)"
  value       = var.ssh_public_key == "" ? var.ssh_key_output_path : ""
}

output "ssh_user" {
  description = "SSH user for Ubuntu AMI"
  value       = "ubuntu"
}

output "ecr_registry" {
  description = "Registry URL (use as IMAGE_REGISTRY)"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_uris" {
  description = "Map of service name to full ECR repository URI"
  value = {
    for name, repo in aws_ecr_repository.svc :
    name => repo.repository_url
  }
}

output "backup_bucket" {
  description = "S3 bucket name for restic backups (empty if not created)"
  value       = var.create_backup_bucket ? aws_s3_bucket.backups[0].id : ""
}

output "restic_repository" {
  description = "Ready-to-paste RESTIC_REPOSITORY for .env"
  value       = var.create_backup_bucket ? "s3:s3.${var.region}.amazonaws.com/${aws_s3_bucket.backups[0].id}" : ""
}

output "iot_data_endpoint" {
  description = "AWS_IOT_ENDPOINT for the app"
  value       = var.enable_iot ? data.aws_iot_endpoint.data[0].endpoint_address : ""
}

output "iot_credential_provider_endpoint" {
  description = "AWS IoT credential provider endpoint (used by devices to fetch KVS credentials)"
  value       = var.enable_iot ? data.aws_iot_endpoint.credentials[0].endpoint_address : ""
}

output "iot_role_alias" {
  description = "AWS_IOT_ROLE_ALIAS for the app"
  value       = var.enable_iot ? aws_iot_role_alias.kvs[0].alias : ""
}

output "iot_device_policy" {
  description = "IoT policy name to attach to device certificates"
  value       = var.enable_iot ? aws_iot_policy.device[0].name : ""
}

# --- DNS ---------------------------------------------------------------------

output "domain_name" {
  description = "FQDN pointed at the instance (empty when Route 53 is disabled)"
  value       = local.route53_enabled ? var.domain_name : ""
}

output "letsencrypt_email" {
  description = "Contact address the CLI uses when bootstrapping TLS"
  value       = var.letsencrypt_email
}

output "route53_zone_id" {
  description = "Hosted zone holding the A record (empty when Route 53 is disabled)"
  value       = local.route53_zone_id
}

output "route53_nameservers" {
  description = "Nameservers to set at your registrar. Only populated when Terraform created the zone."
  value       = local.route53_enabled && var.create_route53_zone ? aws_route53_zone.this[0].name_servers : []
}

output "dns_record_created" {
  description = "True when Terraform manages the A record — the CLI uses this to decide whether to bootstrap TLS automatically"
  value       = local.route53_enabled
}
