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

variable "region" {
  description = "The one region this permission set is valid in."
  type        = string
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
