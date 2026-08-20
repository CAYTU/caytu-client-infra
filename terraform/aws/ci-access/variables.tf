variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  type    = string
  default = ""
}

variable "github_repository" {
  description = "Repository allowed to assume these roles, owner/name."
  type        = string
  default     = "CAYTU/caytu-client-infra"
}

variable "allowed_refs" {
  description = "Which git refs may assume. Widening this widens who can provision."
  type        = list(string)
  default     = ["ref:refs/heads/main"]
}

variable "resource_prefix" {
  description = "Prefix every provisioned resource carries."
  type        = string
  default     = "caytu-"
}

variable "state_bucket" {
  description = "Bucket holding one Terraform state per deployment."
  type        = string
}

variable "state_lock_table" {
  description = "DynamoDB table for state locking. Empty if locking is off."
  type        = string
  default     = ""
}

variable "agent_bucket" {
  description = "Bucket the host agent is published to."
  type        = string
  default     = "caytu-cli"
}

variable "agent_prefix" {
  type    = string
  default = "agent"
}

variable "hosted_dns_zone_ids" {
  description = "Zones holding hosted deployment names, typically caytu.link."
  type        = list(string)
  default     = []
}

variable "customer_role_arns" {
  description = "Provisioner roles in customer accounts this pipeline may assume."
  type        = list(string)
  default     = []
}
