output "cluster_name" {
  value = google_container_cluster.this.name
}

output "cluster_location" {
  value = google_container_cluster.this.location
}

output "kubeconfig_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --location ${google_container_cluster.this.location} --project ${var.project_id}"
}

output "image_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}"
}

output "artifact_repository_uris" {
  value = { for name, repo in google_artifact_registry_repository.svc : name => "${var.region}-docker.pkg.dev/${var.project_id}/${repo.repository_id}" }
}

output "ingress_ip" {
  description = "Global static IP for the ingress. Point your domain here."
  value       = google_compute_global_address.ingress.address
}

output "ingress_ip_name" {
  description = "Name to reference in the Ingress annotation kubernetes.io/ingress.global-static-ip-name"
  value       = google_compute_global_address.ingress.name
}

output "backup_bucket" {
  value = var.create_backup_bucket ? google_storage_bucket.backups[0].name : ""
}

output "wi_backend_annotation" {
  description = "Annotate the 'backend' KSA with this to enable Workload Identity"
  value       = "iam.gke.io/gcp-service-account=${google_service_account.backend.email}"
}

output "wi_backup_annotation" {
  description = "Annotate the 'backup' KSA with this to enable Workload Identity"
  value       = var.create_backup_bucket ? "iam.gke.io/gcp-service-account=${google_service_account.backup[0].email}" : ""
}

output "next_steps" {
  value = <<-EOT

    # 1. Configure kubectl:
    ${google_container_cluster.this.name != "" ? "gcloud container clusters get-credentials ${google_container_cluster.this.name} --location ${google_container_cluster.this.location} --project ${var.project_id}" : "<pending>"}

    # 2. Deploy the app:
    cd kubernetes/overlays/gcp-gke
    cp secrets.env.example secrets.env && $EDITOR secrets.env
    $EDITOR kustomization.yaml     # <REGION>, <PROJECT>, hostname
    $EDITOR managed-cert.yaml      # domain

    caytu-client -t gcp-cluster k8s apply

    # 3. Wire Workload Identity (skip credentials in secrets.env):
    kubectl -n caytu-client annotate serviceaccount backend \
      ${google_service_account.backend.email != "" ? "iam.gke.io/gcp-service-account=${google_service_account.backend.email}" : ""}

    # 4. Point DNS at the global static IP:
    #    caytu.example.com  →  ${google_compute_global_address.ingress.address}
    #    ManagedCertificate takes 15-60 min to provision after DNS resolves.
  EOT
}
