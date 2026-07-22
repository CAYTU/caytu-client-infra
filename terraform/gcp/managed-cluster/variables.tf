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

variable "node_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "node_count" {
  description = "Nodes per zone (multiplied by zone count for regional clusters)"
  type        = number
  default     = 3
}

variable "node_min_count" {
  type    = number
  default = 3
}

variable "node_max_count" {
  type    = number
  default = 10
}

variable "node_preemptible" {
  type    = bool
  default = false
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
