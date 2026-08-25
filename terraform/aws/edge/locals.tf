locals {
  common_tags = {
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
  }
}
