terraform {
  required_version = ">= 1.6.0"

  # These roles are what lets the pipeline into AWS at all, so their state has
  # to outlive whatever checkout somebody happened to apply from. Supplied at
  # init:
  #
  #   terraform init -backend-config="bucket=<state bucket>" \
  #     -backend-config="key=ci-access/terraform.tfstate" \
  #     -backend-config="region=us-east-1" -backend-config="encrypt=true"
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project   = "caytu-client"
      ManagedBy = "terraform"
      Purpose   = "ci-access"
    }
  }
}
