locals {
  name = var.cluster_name

  common_tags = {
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
  }

  # Log groups the add-on's Fluent Bit and agent write to. Created here first so they get a retention (the add-on
  # would create them with "never expire").
  container_insights_log_groups = toset(["application", "dataplane", "host", "performance"])
}
