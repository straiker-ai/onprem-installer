output "models_bucket_name" {
  value = google_storage_bucket.models.name
}

output "artifact_registry_host" {
  description = "global.dockerRegistry value for GKE installs — <registry>/<image-relative-path> resolves the same way as the ECR case."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.mirror.repository_id}"
}

output "hauler_service_account_email" {
  value = google_service_account.hauler.email
}

output "workload_service_account_email" {
  value = google_service_account.workload.email
}
