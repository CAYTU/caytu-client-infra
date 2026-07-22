data "google_project" "current" {}

# -----------------------------------------------------------------------------
# Enable required services (idempotent — no-op if already on)
# -----------------------------------------------------------------------------
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Network references
# -----------------------------------------------------------------------------
data "google_compute_network" "chosen" {
  name = var.network
}

locals {
  subnetwork_ref = var.subnetwork != "" ? var.subnetwork : "default"
}

# -----------------------------------------------------------------------------
# SSH key
# -----------------------------------------------------------------------------
resource "tls_private_key" "generated" {
  count     = var.ssh_public_key == "" ? 1 : 0
  algorithm = "ED25519"
}

resource "local_sensitive_file" "generated_key" {
  count           = var.ssh_public_key == "" ? 1 : 0
  content         = tls_private_key.generated[0].private_key_openssh
  filename        = var.ssh_key_output_path
  file_permission = "0600"
}

locals {
  ssh_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.generated[0].public_key_openssh
}

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------
resource "google_compute_firewall" "ssh" {
  count   = length(var.operator_ssh_cidrs) > 0 ? 1 : 0
  name    = "${var.name_prefix}-${var.environment}-ssh"
  network = data.google_compute_network.chosen.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = var.operator_ssh_cidrs
  target_tags   = ["${var.name_prefix}-${var.environment}"]
}

resource "google_compute_firewall" "http" {
  name    = "${var.name_prefix}-${var.environment}-http"
  network = data.google_compute_network.chosen.self_link

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = var.public_http_cidrs
  target_tags   = ["${var.name_prefix}-${var.environment}"]
}

resource "google_compute_firewall" "turn" {
  count   = var.enable_turn_ports ? 1 : 0
  name    = "${var.name_prefix}-${var.environment}-turn"
  network = data.google_compute_network.chosen.self_link

  allow {
    protocol = "tcp"
    ports    = ["3478", "5349"]
  }
  allow {
    protocol = "udp"
    ports    = ["3478", "5349", "49152-49252"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name_prefix}-${var.environment}"]
}

# -----------------------------------------------------------------------------
# Static external IP
# -----------------------------------------------------------------------------
resource "google_compute_address" "this" {
  name         = "${var.name_prefix}-${var.environment}"
  address_type = "EXTERNAL"
  region       = var.region
}

# -----------------------------------------------------------------------------
# Service account (Artifact Registry pull + GCS backup + logging)
# -----------------------------------------------------------------------------
resource "google_service_account" "instance" {
  account_id   = "${var.name_prefix}-${var.environment}"
  display_name = "caytu-client ${var.environment} instance"
}

resource "google_project_iam_member" "instance_artifact_pull" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.instance.email}"
}

resource "google_project_iam_member" "instance_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.instance.email}"
}

resource "google_project_iam_member" "instance_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.instance.email}"
}

# -----------------------------------------------------------------------------
# GCE instance
# -----------------------------------------------------------------------------
resource "google_compute_instance" "this" {
  name         = "${var.name_prefix}-${var.environment}"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["${var.name_prefix}-${var.environment}"]

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    network    = var.network
    subnetwork = local.subnetwork_ref
    access_config {
      nat_ip = google_compute_address.this.address
    }
  }

  service_account {
    email  = google_service_account.instance.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    ssh-keys               = "${var.ssh_user}:${local.ssh_key}"
    enable-oslogin         = "FALSE" # rely on metadata SSH keys, not OS Login
    block-project-ssh-keys = "TRUE"
    startup-script = <<-EOT
      #!/bin/bash
      set -e
      if [ ! -f /var/lib/caytu-client-bootstrap-done ]; then
        curl -fsSL https://raw.githubusercontent.com/CAYTU/caytu-client-infra/main/scripts/bootstrap.sh \
          | DEPLOY_USER=${var.ssh_user} bash
        touch /var/lib/caytu-client-bootstrap-done
      fi
    EOT
  }

  allow_stopping_for_update = true

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = {
    project     = "caytu-client"
    environment = var.environment
    managed-by  = "terraform"
  }

  depends_on = [
    google_project_service.required,
  ]
}
