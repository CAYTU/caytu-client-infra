variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "environment" {
  type    = string
  default = "staging"
}

variable "name_prefix" {
  type    = string
  default = "caytu-client"
}

# -----------------------------------------------------------------------------
# GKE
# -----------------------------------------------------------------------------
variable "cluster_version" {
  description = "GKE minimum version (uses RAPID release channel)"
  type        = string
  default     = "1.30"
}

variable "regional" {
  description = "true = regional cluster (HA control plane, 3× the node cost); false = zonal (single-zone, cheaper)"
  type        = bool
  default     = false
}

variable "zone" {
  description = "Zone for zonal clusters (ignored when regional=true)"
  type        = string
  default     = "us-central1-a"
}

# -----------------------------------------------------------------------------
# Node pools — split into stateful (on-demand) and stateless (Spot VMs).
# See main.tf for the reasoning.
# -----------------------------------------------------------------------------

# --- Stateful pool (on-demand) ----------------------------------------------
variable "stateful_machine_type" {
  type    = string
  default = "e2-standard-4"    # bigger — MongoDB/MinIO benefit from headroom
}

variable "stateful_node_count" {
  description = "Nodes per zone (multiplied by zone count for regional clusters)"
  type        = number
  default     = 2
}

variable "stateful_min_count" {
  type    = number
  default = 2
}

variable "stateful_max_count" {
  description = "Small cap — data pods scale vertically, not horizontally"
  type        = number
  default     = 3
}

# --- Stateless pool (Spot VMs) ----------------------------------------------
variable "stateless_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "stateless_node_count" {
  type    = number
  default = 2
}

variable "stateless_min_count" {
  type    = number
  default = 2
}

variable "stateless_max_count" {
  type    = number
  default = 10
}

variable "stateless_use_spot" {
  description = "Use Spot VMs for the stateless pool. Set false for prod pilots where you're not ready to trust SPOT eviction handling yet."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
variable "network_cidr" {
  type    = string
  default = "10.70.0.0/16"
}

variable "pods_cidr" {
  type    = string
  default = "10.71.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.72.0.0/20"
}

# -----------------------------------------------------------------------------
# Artifact Registry / GCS
# -----------------------------------------------------------------------------
variable "artifact_repositories" {
  type    = list(string)
  default = ["backend", "frontend", "webrtc-signaling", "gstreamer-recorder", "mqtt-streamer"]
}

variable "create_backup_bucket" {
  type    = bool
  default = true
}

variable "backup_bucket_name" {
  type    = string
  default = ""
}

variable "backup_bucket_location" {
  type    = string
  default = "US"
}
