variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone (must be in region)"
  type        = string
  default     = "us-central1-a"
}

variable "environment" {
  description = "Deployment environment (staging, prod, demo, etc.)"
  type        = string
  default     = "staging"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "caytu-client"
}

# -----------------------------------------------------------------------------
# Instance
# -----------------------------------------------------------------------------
variable "machine_type" {
  description = "GCE machine type. e2-standard-4 (~$100/mo) for staging; n2-standard-4 for prod"
  type        = string
  default     = "e2-standard-4"
}

variable "image" {
  description = "Boot disk image (family/project). Ubuntu 24.04 LTS by default."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 100
}

variable "boot_disk_type" {
  description = "pd-standard | pd-balanced | pd-ssd"
  type        = string
  default     = "pd-balanced"
}

variable "ssh_public_key" {
  description = "Public key content. Leave empty to have Terraform generate an ed25519 pair (private key at ssh_key_output_path)."
  type        = string
  default     = ""
}

variable "ssh_user" {
  description = "OS Login-style user; also written into instance metadata for classic ssh"
  type        = string
  default     = "caytu"
}

variable "ssh_key_output_path" {
  description = "Where to write the generated private key"
  type        = string
  default     = "./ssh_key.pem"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
variable "network" {
  description = "VPC name. Leave 'default' to use the auto-created VPC."
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "Subnetwork name. Leave empty for 'default'."
  type        = string
  default     = ""
}

variable "operator_ssh_cidrs" {
  description = "CIDRs allowed to SSH. Restrict to your office / VPN / bastion."
  type        = list(string)
  default     = []
}

variable "public_http_cidrs" {
  description = "CIDRs allowed for 80/443"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_turn_ports" {
  description = "Open TURN ports (self-hosted WebRTC). Default true for GCP — GCP has no managed KVS."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Artifact Registry
# -----------------------------------------------------------------------------
variable "artifact_repositories" {
  description = "Docker repositories in Artifact Registry"
  type        = list(string)
  default     = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]
}

# -----------------------------------------------------------------------------
# GCS backup bucket
# -----------------------------------------------------------------------------
variable "create_backup_bucket" {
  description = "Create a GCS bucket for restic offsite backups"
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "GCS bucket name. Leave empty for auto-generated"
  type        = string
  default     = ""
}

variable "backup_bucket_lifecycle_days" {
  description = "Move backup objects to Archive after N days (0 = disabled)"
  type        = number
  default     = 90
}

variable "backup_bucket_location" {
  description = "GCS location (US, EU, or specific region). Multi-region is durable but pricier."
  type        = string
  default     = "US"
}
