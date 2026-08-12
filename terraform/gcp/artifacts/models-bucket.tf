resource "google_storage_bucket" "models" {
  project  = var.project_id
  name     = "${var.prefix}-models-${var.region}-${var.project_id}"
  location = var.region

  versioning {
    enabled = true
  }
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = local.common_labels

  depends_on = [google_project_service.required]
}
