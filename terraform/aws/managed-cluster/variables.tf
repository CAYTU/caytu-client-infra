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
# Node groups — split into stateful (on-demand, EBS-anchored workloads) and
# stateless (SPOT, ~70% cheaper). See main.tf for the reasoning.
# -----------------------------------------------------------------------------

# --- Stateful pool (on-demand) ----------------------------------------------
variable "stateful_instance_types" {
  description = "Instance type(s) for the on-demand pool that hosts MongoDB/Redis/MinIO/gstreamer"
  type        = list(string)
  default     = ["m6i.large"]
}

variable "stateful_min_size" {
  type    = number
  default = 2
}

variable "stateful_desired_size" {
  type    = number
  default = 2
}

# The ceiling the autoscaler may grow into. Not a target: nodes are only added
# when a pod cannot be placed, so a higher ceiling costs nothing until it is
# needed, and a low one turns a traffic spike into pending pods.
variable "stateful_max_size" {
  description = "Cap on stateful pool; usually small — data pods scale vertically, not horizontally"
  type        = number
  default     = 3
}

# --- Stateless pool (SPOT) ---------------------------------------------------
# Several types on purpose. SPOT capacity is per type per zone, so one type is
# one thing to run out of; AWS substitutes from this list instead of failing.
# Keep them the same size or the autoscaler's decisions get unpredictable.
variable "stateless_instance_types" {
  description = "Diversified type list for SPOT. Keep them same-size so HPA scaling is predictable."
  type        = list(string)
  default     = ["m6i.large", "m5.large", "m5a.large", "m5n.large"]
}

variable "stateless_min_size" {
  type    = number
  default = 2
}

variable "stateless_desired_size" {
  type    = number
  default = 3
}

variable "stateless_max_size" {
  type    = number
  default = 10
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
