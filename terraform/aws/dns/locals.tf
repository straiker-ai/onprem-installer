locals {
  common_tags = {
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
  }

  # The zone the gateway certificate's validation records go into: the one created here, or the existing public zone
  # of this account that has exactly the name var.domain.
  zone_id = var.create_zone ? aws_route53_zone.this[0].zone_id : try(data.aws_route53_zone.existing[0].zone_id, "")
}
