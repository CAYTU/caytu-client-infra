variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "default"
}

variable "environment" {
  description = "Deployment environment (staging, prod, demo, etc.)"
  type        = string
  default     = "staging"
}

variable "name_prefix" {
  description = "Prefix for all resource names — makes cohabiting deployments in one account safe"
  type        = string
  default     = "caytu-client"
}

# -----------------------------------------------------------------------------
# Instance
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type. r6g.large (~$120/mo) works for staging; m6g.xlarge for prod"
  type        = string
  default     = "r6g.large"
}

variable "instance_arch" {
  description = "arm64 (Graviton, cheaper) or amd64 (x86)"
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "amd64"], var.instance_arch)
    error_message = "instance_arch must be one of: arm64, amd64"
  }
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
  default     = "gp3"
}

variable "ssh_public_key" {
  description = "Public key content (ssh-rsa/ed25519) for the instance. Leave empty to have Terraform generate a key pair (private key written to ssh_key_output_path)."
  type        = string
  default     = ""
}

variable "ssh_key_output_path" {
  description = "Where to write the generated private key when ssh_public_key is empty"
  type        = string
  default     = "./ssh_key.pem"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
variable "vpc_id" {
  description = "Existing VPC to place the instance in. Leave empty to use the account's default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Existing subnet. Leave empty to use one from the default VPC."
  type        = string
  default     = ""
}

variable "operator_ssh_cidrs" {
  description = "CIDRs allowed to SSH. Restrict to your office / VPN / bastion IPs."
  type        = list(string)
  default     = []
}

variable "public_http_cidrs" {
  description = "CIDRs allowed for 80/443 (usually [\"0.0.0.0/0\"])"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_turn_ports" {
  description = "Open 3478/5349/49152-49252 for self-hosted TURN. Leave false for AWS (uses KVS)."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# ECR
# -----------------------------------------------------------------------------
variable "ecr_repositories" {
  description = "Repositories to create for image pulls"
  type        = list(string)
  default     = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]
}

variable "ecr_image_tag_mutability" {
  description = "MUTABLE lets you re-push :latest; IMMUTABLE forbids reuse"
  type        = string
  default     = "MUTABLE"
}

# -----------------------------------------------------------------------------
# S3 backup bucket
# -----------------------------------------------------------------------------
variable "create_backup_bucket" {
  description = "Create an S3 bucket for restic offsite backups"
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "S3 bucket name. Leave empty for auto-generated <name_prefix>-backups-<random>"
  type        = string
  default     = ""
}

variable "backup_bucket_lifecycle_days" {
  description = "Move backup objects to Glacier after N days (0 = disabled)"
  type        = number
  default     = 90
}

# -----------------------------------------------------------------------------
# IoT device auth (managed MQTT + KVS)
# -----------------------------------------------------------------------------
variable "enable_iot" {
  description = "Provision AWS IoT policy + role alias for device auth (needed for STREAMING_PROVIDER=kvs)"
  type        = bool
  default     = true
}

variable "iot_role_alias_ttl_seconds" {
  description = "TTL for temporary credentials issued via the IoT role alias"
  type        = number
  default     = 3600
}
