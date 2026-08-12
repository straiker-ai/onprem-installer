data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
  }

  # Relative image paths — must match charts/straiker-system's global.dockerRegistry
  # mirroring setup (nvidia.devicePlugin.image.repository, opensearch subchart's
  # default repo). ECR repos are created as "${var.prefix}/<name>". Add more here
  # as more images join that mirroring pattern.
  image_names = [
    "nvidia/k8s-device-plugin",
    "opensearchproject/opensearch",
  ]
}
