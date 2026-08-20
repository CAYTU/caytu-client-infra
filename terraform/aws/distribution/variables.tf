variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  description = "Local profile. Empty uses environment credentials."
  type        = string
  default     = ""
}

variable "customer_accounts" {
  description = "Accounts allowed to pull images and fetch the agent. One entry per customer deployment account."
  type = list(object({
    account_id      = string
    label           = string
    resource_prefix = optional(string, "caytu-")
  }))
  default = []
}

variable "image_repositories" {
  description = "Repositories a deployment pulls from."
  type        = list(string)
  default = [
    "caytu-client-backend",
    "caytu-client-frontend",
    "caytu-client-mqtt-streamer",
    "caytu-client-gstreamer-recorder",
    "caytu-client-signaling-server",
  ]
}

variable "agent_bucket" {
  description = "Bucket holding the host agent tarball and the public apt repository."
  type        = string
  default     = "caytu-cli"
}

variable "agent_prefix" {
  description = "Prefix the agent lives under. Everything here is private."
  type        = string
  default     = "agent"
}

variable "public_objects" {
  description = "Keys and prefixes that are meant to be world readable: the apt repository and the installer."
  type        = list(string)
  default = [
    "dists/*",
    "pool/*",
    "dist/*",
    "caytu-archive-keyring.gpg",
    "install.sh",
    "setup.sh",
  ]
}
