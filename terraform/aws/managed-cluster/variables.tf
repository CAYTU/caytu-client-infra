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
  description = "EKS Kubernetes version. Empty lets AWS pick its current default, which is what you want: a pinned version ages into extended support and is billed at six times the standard rate."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}

variable "availability_zones" {
  description = "Zones to spread the cluster across. Empty picks the first three the region has, which is what you want unless a region is short of capacity in one."
  type        = list(string)
  default     = []
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

# -----------------------------------------------------------------------------
# Building in an account we do not own
# -----------------------------------------------------------------------------
# Both empty on a Caytu-hosted apply, which is the default.

variable "assume_role_arn" {
  description = "Role to assume in the target account. Empty runs with the caller's own credentials."
  type        = string
  default     = ""
}

variable "assume_role_external_id" {
  description = "External id that account requires. Only meaningful with assume_role_arn."
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# The name the cluster answers on, and the certificate for it.
#
# A single machine gets its certificate from Let's Encrypt, on the machine. A
# cluster answers behind a load balancer, which wants an ACM certificate in the
# same account and region. Nothing was creating one, so certificate_arn had to
# be filled in by hand or the build failed at the ingress.
# -----------------------------------------------------------------------------

variable "domain_name" {
  description = "FQDN the cluster answers on, e.g. \"client.caytu.link\". Empty skips the certificate and DNS entirely."
  type        = string
  default     = ""
}

variable "route53_zone_name" {
  description = "Zone holding that name, e.g. \"caytu.link\". Ours, even when the cluster is in someone else's account."
  type        = string
  default     = ""
}

variable "dns_region" {
  description = "Route 53 is global but the provider still needs a region."
  type        = string
  default     = "us-east-1"
}

variable "dns_assume_role_arn" {
  description = "Role that may write the zone. Empty means the credentials already in the environment, which is our own pipeline."
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "An existing certificate to use instead of creating one. Empty with domain_name set means create it."
  type        = string
  default     = ""
}

variable "iam_permissions_boundary" {
  description = "Boundary every role this stack creates must carry. Required in a customer account, where CreateRole without it is refused outright. Empty in our own."
  type        = string
  default     = ""
}

variable "web_identity_token_file" {
  description = <<-EOT
    A token GitHub minted for this run, on disk, for a customer account whose
    role trusts GitHub directly rather than a role in ours. Set together with
    assume_role_arn and instead of assume_role_external_id.
  EOT
  type        = string
  default     = ""
}
