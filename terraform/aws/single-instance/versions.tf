terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Partial on purpose: everything is supplied at `terraform init`, because the
  # state key has to differ per deployment.
  #
  # A single shared key would be quietly catastrophic here. Every deployment uses
  # this same configuration, so one state file means provisioning the second
  # customer sees the first customer's instance as "the" instance and destroys it
  # to make room. Each deployment gets its own key:
  #
  #   terraform init -backend-config="key=instances/<deployment-id>/terraform.tfstate"
  #
  # There is no local-state fallback: with this block present `init` fails until
  # a backend is given. That is the intent. State on a laptop for a machine a
  # customer is running is state that gets lost. A throwaway local run can pass
  # `-backend=false`, which only allows validate and plan.
  backend "s3" {}
}

provider "aws" {
  region = var.region
  # Empty means "use whatever credentials the environment provides", which is
  # what CI has. Naming a profile there would send Terraform looking for a
  # ~/.aws/credentials that does not exist on a runner.
  profile = var.aws_profile != "" ? var.aws_profile : null

  # Present only when the machine belongs in someone else's account. Without
  # it this is the Caytu-hosted path, unchanged.
  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" ? [1] : []
    content {
      role_arn     = var.assume_role_arn
      external_id  = var.assume_role_external_id != "" ? var.assume_role_external_id : null
      session_name = "caytu-provision-${var.name_prefix}"
    }
  }

  default_tags {
    tags = {
      Project     = "caytu-client"
      ManagedBy   = "terraform"
      Deployment  = "single-instance"
      Environment = var.environment
    }
  }
}

# Route 53 separately, because the name and the machine do not have to live in
# the same account. A caytu.link record stays ours to write even when the EC2
# instance is provisioned in a customer account through assume_role above.
provider "aws" {
  alias   = "dns"
  region  = var.dns_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  dynamic "assume_role" {
    for_each = var.dns_assume_role_arn != "" ? [1] : []
    content {
      role_arn     = var.dns_assume_role_arn
      session_name = "caytu-dns-${var.name_prefix}"
    }
  }
}
