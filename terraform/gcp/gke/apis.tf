resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Real, currently-UP zones for the region -- see locals.tf's provision_strategy
# handling. Depends on compute.googleapis.com already being enabled.
data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
  status  = "UP"

  depends_on = [google_project_service.required]
}
