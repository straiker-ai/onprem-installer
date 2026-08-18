data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
  }

  # Relative image paths — must match charts/straiker-artifact/values.yaml's
  # imageMirror.images[].destRepository (source of the actual mirror) and
  # charts/straiker-system's own image repository values (nvidia.devicePlugin.image.repository,
  # opensearch subchart's default repo, etc. — the chart's own pulls once
  # global.dockerRegistry points at the mirror). ECR repos are created as
  # "${var.prefix}/<name>". Add here whenever an image joins that list.
  image_names = [
    "nvidia/k8s-device-plugin",
    "opensearchproject/opensearch",
    "timberio/vector",
    "valkey/valkey",
    "library/postgres",
    "maximhq/bifrost",
    "dexidp/dex",
    "library/caddy",
    "redpandadata/connect",
    "straiker/frontend",
    "straiker/frontend-migrate",
    "straiker/vllm",
    "straiker/argus",
    "straiker/iris",
  ]
}
