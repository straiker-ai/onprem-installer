locals {
  common_labels = {
    vendor      = "straiker"
    build       = "onprem"
    managed_by  = "terraform"
    environment = "onprem"
  }
}

resource "google_project_service" "required" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
