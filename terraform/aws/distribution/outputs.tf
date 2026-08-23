output "public_objects" {
  description = "What stays world readable. Everything else in the bucket, the agent included, does not."
  value       = var.public_objects
}
