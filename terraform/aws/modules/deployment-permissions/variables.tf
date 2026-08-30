# One definition of what provisioning a deployment needs, used twice: by the
# role a customer creates for us, and by our own pipeline role. Two copies of
# this list would drift, and the drift only shows up as a failed apply on a
# customer's machine.

variable "account_id" {
  description = "Account the deployment is created in."
  type        = string
}

variable "partition" {
  type    = string
  default = "aws"
}

variable "regions" {
  description = "Regions this permission set is valid in. A customer role gets one; our own pipeline needs every region we provision in."
  type        = list(string)

  validation {
    condition     = length(var.regions) > 0
    error_message = "At least one region, or the role can do nothing anywhere."
  }
}

variable "resource_prefix" {
  description = "Everything created must start with this."
  type        = string
  default     = "caytu-"
}

variable "boundary_arn" {
  description = "Boundary every created role must carry. Empty drops the requirement, which is right in our own account."
  type        = string
  default     = ""
}

variable "allow_route53" {
  description = "Whether the DNS zone lives in this account."
  type        = bool
  default     = false
}

variable "route53_zone_ids" {
  description = "Zones that may be written. Empty with allow_route53 means every zone."
  type        = list(string)
  default     = []
}

variable "protected_role_arns" {
  description = "Roles this permission set must never be able to rewrite, typically the role it is attached to. Empty in a customer account, where the boundary already closes it."
  type        = list(string)
  default     = []
}

variable "include_cluster" {
  description = "Whether this account may hold an EKS cluster. A cluster needs its own network, an OIDC provider and a key, none of which a single machine uses, so it is asked for rather than granted by default."
  type        = bool
  default     = false
}
