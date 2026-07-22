# Workload Identity: bind GCP service accounts to k8s ServiceAccounts.
# Pods with the KSA annotation `iam.gke.io/gcp-service-account` assume the
# bound GSA without needing static key material.

# --- Backend GSA ------------------------------------------------------------
resource "google_service_account" "backend" {
  account_id   = "${var.name_prefix}-${var.environment}-backend"
  display_name = "caytu-client backend workload"
}

# Bind to k8s ServiceAccount "backend" in the caytu-client namespace.
resource "google_service_account_iam_member" "backend_wi" {
  service_account_id = google_service_account.backend.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[caytu-client/backend]"
}

# Grants to the backend GSA: read-only Artifact Registry, secret access, log/monitor.
# Tighten to specific resources for prod.
resource "google_project_iam_member" "backend_artifact_pull" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

# --- Backup GSA (for a CronJob writing to the GCS backup bucket) ------------
resource "google_service_account" "backup" {
  count        = var.create_backup_bucket ? 1 : 0
  account_id   = "${var.name_prefix}-${var.environment}-backup"
  display_name = "caytu-client backup CronJob"
}

resource "google_service_account_iam_member" "backup_wi" {
  count              = var.create_backup_bucket ? 1 : 0
  service_account_id = google_service_account.backup[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[caytu-client/backup]"
}
