variable "region" {
  description = "Region the deployment will live in. Also the only region this access is valid for."
  type        = string
}

variable "aws_profile" {
  description = "Local profile to run this with. Empty uses environment credentials."
  type        = string
  default     = ""
}

variable "caytu_principal_arns" {
  description = "The Caytu identities allowed to assume this role, e.g. the provisioning pipeline's role ARN."
  type        = list(string)
}

variable "external_id" {
  description = "Shared value Caytu must present when assuming the role. Leave empty to generate one."
  type        = string
  default     = ""
  sensitive   = true
}

variable "role_name" {
  description = "Name of the role Caytu assumes."
  type        = string
  default     = "CaytuProvisioner"
}

variable "resource_prefix" {
  description = "Every resource Caytu may create or touch must start with this. Widening it widens the blast radius."
  type        = string
  default     = "caytu-"
}

variable "session_duration_seconds" {
  description = "How long one assumed session lasts. A provision takes well under an hour."
  type        = number
  default     = 3600
}

variable "allow_route53" {
  description = "Only when the DNS zone lives in this account. Caytu writes caytu.link records from its own account."
  type        = bool
  default     = false
}

variable "route53_zone_ids" {
  description = "Zones Caytu may write records in. Empty with allow_route53 = true means every zone."
  type        = list(string)
  default     = []
}

variable "include_cluster" {
  description = "Whether this account may hold an EKS cluster as well as single machines. Grants network, OIDC and key permissions a single machine never uses."
  type        = bool
  default     = false
}
