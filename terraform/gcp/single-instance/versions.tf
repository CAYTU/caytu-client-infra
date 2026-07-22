terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state (recommended for prod). Bucket must exist before init.
  # backend "gcs" {
  #   bucket = "caytu-client-tf-state"
  #   prefix = "gcp/single-instance"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
