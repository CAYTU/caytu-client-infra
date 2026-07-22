output "public_ip" {
  description = "Static external IP attached to the instance"
  value       = google_compute_address.this.address
}

output "instance_name" {
  description = "GCE instance name"
  value       = google_compute_instance.this.name
}

output "instance_zone" {
  description = "Zone the instance is in"
  value       = var.zone
}

output "machine_type" {
  description = "Machine type"
  value       = google_compute_instance.this.machine_type
}

output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "ssh_key_path" {
  description = "Local path to the generated SSH private key (empty if operator supplied ssh_public_key)"
  value       = var.ssh_public_key == "" ? var.ssh_key_output_path : ""
}

output "ssh_user" {
  description = "SSH user"
  value       = var.ssh_user
}

output "artifact_registry_host" {
  description = "Registry hostname (use with docker login + as IMAGE_REGISTRY prefix)"
  value       = "${var.region}-docker.pkg.dev"
}

output "image_registry" {
  description = "Full IMAGE_REGISTRY path (region-docker.pkg.dev/project/prefix-svc lives under this)"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}"
}

output "artifact_repository_uris" {
  description = "Map of service to full Artifact Registry URI"
  value = {
    for name, repo in google_artifact_registry_repository.svc :
    name => "${var.region}-docker.pkg.dev/${var.project_id}/${repo.repository_id}"
  }
}

output "backup_bucket" {
  description = "GCS bucket for restic (empty if not created)"
  value       = var.create_backup_bucket ? google_storage_bucket.backups[0].name : ""
}

output "restic_repository" {
  description = "Ready-to-paste RESTIC_REPOSITORY for .env"
  value       = var.create_backup_bucket ? "gs:${google_storage_bucket.backups[0].name}:/" : ""
}

output "service_account_email" {
  description = "Service account attached to the instance (used for auto-auth to Artifact Registry / GCS)"
  value       = google_service_account.instance.email
}
