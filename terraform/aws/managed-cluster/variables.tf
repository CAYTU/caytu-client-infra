variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  type    = string
  default = "default"
}

variable "environment" {
  type    = string
  default = "staging"
}

variable "name_prefix" {
  type    = string
  default = "caytu-client"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.30"
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.60.101.0/24", "10.60.102.0/24", "10.60.103.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.60.1.0/24", "10.60.2.0/24", "10.60.3.0/24"]
}

# -----------------------------------------------------------------------------
# Node groups
# -----------------------------------------------------------------------------
variable "node_instance_types" {
  description = "Instance types for the primary managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 5
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "operator_admin_arns" {
  description = "IAM ARNs granted system:masters access to the cluster (via EKS access entries)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# ECR + IoT (same shape as single-instance)
# -----------------------------------------------------------------------------
variable "ecr_repositories" {
  type    = list(string)
  default = ["backend", "frontend", "gstreamer-recorder", "mqtt-streamer"]
  # No webrtc-signaling for aws-cluster — KVS replaces it
}

variable "enable_iot" {
  type    = bool
  default = true
}

variable "iot_role_alias_ttl_seconds" {
  type    = number
  default = 3600
}

# -----------------------------------------------------------------------------
# S3 backups
# -----------------------------------------------------------------------------
variable "create_backup_bucket" {
  type    = bool
  default = true
}

variable "backup_bucket_name" {
  type    = string
  default = ""
}
