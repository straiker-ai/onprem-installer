# Separate from the hauler SA: this is for the actual inference/model-serving
# and tokenizer-pull workloads (charts/straiker-inference's and
# charts/straiker-defend's "straiker-inference"/"straiker-defend"
# ServiceAccounts) to read synced models/tokenizers back out of GCS —
# read-only, and never needs Artifact Registry (nodes pull images, not pods).
resource "google_service_account" "workload" {
  project      = var.project_id
  account_id   = "${var.prefix}-models-reader"
  display_name = "Straiker onprem models reader"
}

resource "google_storage_bucket_iam_member" "workload_models_read" {
  bucket = google_storage_bucket.models.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.workload.email}"
}

resource "google_service_account_iam_member" "workload_workload_identity" {
  count = (var.workload_namespace != "" && var.workload_service_account_name != "") ? 1 : 0

  service_account_id = google_service_account.workload.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[${var.workload_namespace}/${var.workload_service_account_name}]"
}
