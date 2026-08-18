# GCP SA for the in-cluster hauling Jobs (image-mirror + model-sync). Bound
# to the K8s ServiceAccount below via Workload Identity — GCP's equivalent of
# terraform/aws/artifacts/hauler.tf's EKS Pod Identity association.
resource "google_service_account" "hauler" {
  project      = var.project_id
  account_id   = "${var.prefix}-artifact-hauler"
  display_name = "Straiker onprem artifact hauler"
}

# Writer on the repo itself rather than a project-wide role — same
# least-privilege intent as the AWS side's ECR policy being scoped to
# repositories, not the whole account.
resource "google_artifact_registry_repository_iam_member" "hauler_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.mirror.location
  repository = google_artifact_registry_repository.mirror.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.hauler.email}"
}

resource "google_storage_bucket_iam_member" "hauler_models_admin" {
  bucket = google_storage_bucket.models.name
  # objectAdmin, not the coarser legacyBucketWriter — get/put/delete on
  # objects (needed for rclone sync's mirror+delete) without also granting
  # bucket-level ACL/metadata changes.
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.hauler.email}"
}

resource "google_service_account_iam_member" "hauler_workload_identity" {
  service_account_id = google_service_account.hauler.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.service_account_name}]"
}
