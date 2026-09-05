terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Empty on purpose. Every setting is passed at init, because the key is per
  # deployment:
  #
  #   terraform init -backend-config="key=instances/<deployment-id>/cluster.tfstate"
  #
  # There is no local-state fallback: with this block present `init` fails until
  # a backend is given. That is the intent, and it matters more here than
  # anywhere else. A cluster whose state was written to a runner's disk cannot
  # be changed or destroyed afterwards, and it keeps billing.
  #
  # It was commented out, which meant the workflow's own guard against exactly
  # this passed while `init` quietly used local state.
  backend "s3" {}
}

provider "aws" {
  region = var.region
  # Empty means environment credentials, which is what a runner has. Naming a
  # profile there sends terraform looking for a file that is not present.
  profile = var.aws_profile != "" ? var.aws_profile : null

  # Only for someone else's account, and one shape or the other: a role of
  # ours that theirs trusts, or a token minted for this run. Never both.
  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" && var.web_identity_token_file == "" ? [1] : []
    content {
      role_arn     = var.assume_role_arn
      external_id  = var.assume_role_external_id != "" ? var.assume_role_external_id : null
      session_name = "caytu-provision-${var.name_prefix}"
    }
  }

  dynamic "assume_role_with_web_identity" {
    for_each = var.assume_role_arn != "" && var.web_identity_token_file != "" ? [1] : []
    content {
      role_arn                = var.assume_role_arn
      web_identity_token_file = var.web_identity_token_file
      session_name            = "caytu-provision-${var.name_prefix}"
    }
  }

  default_tags {
    tags = {
      Project     = "caytu-client"
      ManagedBy   = "terraform"
      Deployment  = "managed-cluster"
      Environment = var.environment
    }
  }
}

# Kubernetes/Helm providers auth against the EKS cluster right after it's created.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# Route 53 separately, because the name and the cluster do not have to live in
# the same account. A caytu.link record stays ours to write even when the
# cluster is provisioned in a customer account through assume_role above.
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
