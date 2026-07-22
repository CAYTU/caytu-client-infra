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

  # Uncomment and adjust for durable remote state. Bucket + DynamoDB table must
  # exist before `terraform init` — see docs/aws-single-instance.md.
  # backend "s3" {
  #   bucket         = "caytu-client-tf-state"
  #   key            = "aws-single-instance/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "caytu-client-tf-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "caytu-client"
      ManagedBy   = "terraform"
      Deployment  = "single-instance"
      Environment = var.environment
    }
  }
}
