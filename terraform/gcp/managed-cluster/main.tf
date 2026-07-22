data "google_project" "current" {}

# -----------------------------------------------------------------------------
# Enable required services
# -----------------------------------------------------------------------------
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# VPC + subnet
# -----------------------------------------------------------------------------
resource "google_compute_network" "this" {
  name                    = "${var.name_prefix}-${var.environment}"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.required]
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name_prefix}-${var.environment}"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.network_cidr

  # Secondary ranges for GKE VPC-native (alias IP)
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

# NAT for private nodes to reach the internet (Artifact Registry, apt, etc.)
resource "google_compute_router" "nat" {
  name    = "${var.name_prefix}-${var.environment}"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.name_prefix}-${var.environment}"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# -----------------------------------------------------------------------------
# GKE cluster
# -----------------------------------------------------------------------------
resource "google_container_cluster" "this" {
  provider = google-beta

  name     = "${var.name_prefix}-${var.environment}"
  location = var.regional ? var.region : var.zone

  # Manage the primary node pool separately
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.this.name
  subnetwork = google_compute_subnetwork.this.name

  min_master_version = var.cluster_version
  release_channel { channel = "REGULAR" }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    http_load_balancing        { disabled = false }
    horizontal_pod_autoscaling { disabled = false }
    gce_persistent_disk_csi_driver_config { enabled = true }
    network_policy_config      { disabled = true }
    dns_cache_config           { enabled = true }
  }

  deletion_protection = false  # flip to true for prod

  depends_on = [google_project_service.required]
}

resource "google_container_node_pool" "primary" {
  name       = "primary"
  location   = google_container_cluster.this.location
  cluster    = google_container_cluster.this.name

  initial_node_count = var.node_count

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 50
    disk_type    = "pd-balanced"
    preemptible  = var.node_preemptible

    service_account = google_service_account.node.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = { environment = var.environment }
    tags   = ["${var.name_prefix}-${var.environment}"]
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# -----------------------------------------------------------------------------
# Node service account (least privilege for the kubelet)
# -----------------------------------------------------------------------------
resource "google_service_account" "node" {
  account_id   = "${var.name_prefix}-${var.environment}-node"
  display_name = "GKE node service account"
}

resource "google_project_iam_member" "node_artifact_pull" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_project_iam_member" "node_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_project_iam_member" "node_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.node.email}"
}

# -----------------------------------------------------------------------------
# Global static IP for the ingress (referenced by the GCE Ingress annotation)
# -----------------------------------------------------------------------------
resource "google_compute_global_address" "ingress" {
  name         = "caytu-client-ingress"
  address_type = "EXTERNAL"
}
