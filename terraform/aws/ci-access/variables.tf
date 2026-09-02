variable "region" {
  description = "Region for this module's own provider and for the state lock table."
  type        = string
  default     = "us-east-1"
}

variable "deployment_regions" {
  description = <<-EOT
    Every region we may provision a deployment in.

    Must match InstanceRegion in the platform's billings schema. A region the
    wizard offers and this list omits is denied at apply time, part way through
    building a machine, which is the failure this list exists to prevent.

    af-south-1 is opt-in and has to be enabled on the account before an apply
    there can work.
  EOT
  type        = list(string)
  default = [
    "us-east-1",
    "us-east-2",
    "eu-west-3",
    "eu-central-1",
    "af-south-1",
  ]
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

variable "template_prefix" {
  description = "Prefix the customer access template is published under. Public."
  type        = string
  default     = "cloudformation"
}

variable "hosted_dns_zone_ids" {
  description = "Zones holding hosted deployment names, typically caytu.link."
  type        = list(string)
  default     = []
}

variable "customer_role_arns" {
  description = <<-EOT
    Roles in customer accounts this pipeline may assume.

    A pattern rather than a list, because the list is not the security boundary
    and keeping it accurate meant an apply per customer. What actually gates
    this is on their side: their trust policy names our exact role and demands
    an external id only we hold, so a role we are not meant to touch cannot be
    assumed whatever this says.

    Narrow it to explicit arns if you would rather have both.
  EOT
  type        = list(string)
  default     = ["arn:aws:iam::*:role/CaytuProvisioner"]
}

variable "ci_access_allowed_refs" {
  description = <<-EOT
    Refs that may assume the applying role. Includes pull_request, because the
    plan on a pull request is the whole point of reviewing a permission change
    and a pull request's subject is not the branch's.

    That does mean a pull request can obtain this role, so the workflow only
    ever plans on one. Opening a pull request here already requires push access,
    which is what makes that acceptable; it would not be on a public repository.
  EOT
  type        = list(string)
  default     = ["ref:refs/heads/main", "pull_request"]
}
