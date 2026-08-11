variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Set it empty to use the environment's credentials, which is what CI does."
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
# DNS (Route 53)
# -----------------------------------------------------------------------------
# All off by default — leaving enable_route53 = false creates zero DNS resources
# and the deployment behaves exactly as it did before this was added.
variable "enable_route53" {
  description = "Create a Route 53 A record pointing domain_name at the instance's Elastic IP"
  type        = bool
  default     = false

  validation {
    # Catch the misconfiguration at plan time rather than halfway through apply.
    condition     = !var.enable_route53 || (var.route53_zone_name != "" && var.domain_name != "")
    error_message = "enable_route53 = true requires both route53_zone_name (e.g. \"caytu.link\") and domain_name (e.g. \"client.caytu.link\")."
  }
}

variable "create_route53_zone" {
  description = "false = attach to an existing hosted zone (looked up by route53_zone_name); true = create the zone, after which you must point your registrar at the emitted nameservers"
  type        = bool
  default     = false
}

variable "route53_zone_name" {
  description = "Apex hosted zone, e.g. \"caytu.link\""
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "FQDN the instance answers on, e.g. \"client.caytu.link\". Must sit inside route53_zone_name."
  type        = string
  default     = ""
}

variable "route53_record_ttl" {
  description = "TTL for the A record. Kept low so the record follows the EIP quickly if it ever changes."
  type        = number
  default     = 60
}

variable "route53_allow_overwrite" {
  description = "Adopt an existing record with the same name/type instead of failing the apply"
  type        = bool
  default     = false
}

variable "letsencrypt_email" {
  description = "Contact address for Let's Encrypt. Required for the CLI to bootstrap TLS automatically after provisioning."
  type        = string
  default     = ""
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

# ── Caytu hosted ─────────────────────────────────────────────────────────────
# Set when this machine is being created for a specific deployment. With both of
# these the instance enrols itself on first boot and provisions without anyone
# logging in. Neither is a secret: the credential is issued against the identity
# document AWS signs for the instance, not against anything carried here.

variable "caytu_instance_id" {
  description = "The platform's deployment record this machine is created for. Empty means an unattached machine that an operator will enrol by hand."
  type        = string
  default     = ""
}

variable "caytu_platform_url" {
  description = "Where the platform lives, e.g. https://caytu.link"
  type        = string
  default     = ""
}
