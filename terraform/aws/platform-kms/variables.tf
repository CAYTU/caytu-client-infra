variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  description = "Local profile. Empty uses environment credentials."
  type        = string
  default     = ""
}

variable "platform_role_name" {
  description = "Instance role the platform services run under."
  type        = string
  default     = "caytu-ssm"
}
