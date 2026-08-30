output "key_arn" {
  description = "Set as PLATFORM_KMS_KEY_ARN on the platform services."
  value       = aws_kms_key.deployment_secrets.arn
}

output "key_alias" {
  value = aws_kms_alias.deployment_secrets.name
}
