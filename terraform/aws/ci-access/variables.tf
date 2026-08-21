variable "region" {
  description = "Region for this module's own provider and for the state lock table."
  type        = string
  default     = "us-east-1"
}

variable "deployment_regions" {
  description = "Every region we may provision a deployment in. A region left out here is denied at apply time, part way through building a machine."
  type        = list(string)
  default     = ["us-east-1", "eu-west-3"]
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

variable "github_repository_immutable" {
  description = <<-EOT
    The same repository in the form GitHub actually puts in the token, with the
    owner and repository ids embedded. GitHub issues this rather than the plain
    name, so a trust policy matching only the plain form is refused with
    "Not authorized to perform sts:AssumeRoleWithWebIdentity".

    Read it from:
      gh api /repos/<owner>/<repo>/actions/oidc/customization/sub

    Empty falls back to the plain name alone, which is what a repository still
    issuing the old form needs.
  EOT
  type        = string
  default     = "CAYTU@90842686/caytu-client-infra@1308651827"
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
