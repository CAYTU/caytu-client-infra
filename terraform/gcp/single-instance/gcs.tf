# GCS bucket for restic offsite backups.

resource "random_id" "backup_bucket" {
  count       = var.create_backup_bucket && var.backup_bucket_name == "" ? 1 : 0
  byte_length = 4
}

locals {
  backup_bucket_name = var.create_backup_bucket ? (
    var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.name_prefix}-${var.environment}-backups-${random_id.backup_bucket[0].hex}"
  ) : ""
}

resource "google_storage_bucket" "backups" {
  count                       = var.create_backup_bucket ? 1 : 0
  name                        = local.backup_bucket_name
  location                    = var.backup_bucket_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  dynamic "lifecycle_rule" {
    for_each = var.backup_bucket_lifecycle_days > 0 ? [1] : []
    content {
      condition {
        age = var.backup_bucket_lifecycle_days
      }
      action {
        type          = "SetStorageClass"
        storage_class = "ARCHIVE"
      }
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_iam_member" "backups_writer" {
  count  = var.create_backup_bucket ? 1 : 0
  bucket = google_storage_bucket.backups[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.instance.email}"
}
