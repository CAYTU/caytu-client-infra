resource "google_artifact_registry_repository" "svc" {
  for_each = toset(var.artifact_repositories)

  location      = var.region
  repository_id = "${var.name_prefix}-${each.value}"
  description   = "caytu-client ${each.value}"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-last-30-tagged"
    action = "KEEP"
    most_recent_versions {
      keep_count = 30
    }
  }
  cleanup_policies {
    id     = "drop-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s"
    }
  }

  depends_on = [google_project_service.required]
}
