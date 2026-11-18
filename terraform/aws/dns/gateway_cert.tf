# TLS certificate of the API gateway (api.<domain>), DNS-validated in the zone of this stack. Tagged exactly as the
# installer's own CLI request tags it, so the gateway-cert phase finds this one (gateway_cert_find) and reuses it.
resource "aws_acm_certificate" "gateway" {
  count = var.gateway_domain != "" ? 1 : 0

  domain_name       = var.gateway_domain
  validation_method = "DNS"

  tags = merge(local.common_tags, {
    "straiker:cluster" = var.cluster_name
    managed_by         = "straiker-installer"
  })

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.gateway_domain == var.domain || endswith(var.gateway_domain, ".${var.domain}")
      error_message = "gateway_domain must be the domain itself or a host under it, so that its validation record belongs in this zone."
    }
  }
}

resource "aws_route53_record" "gateway_validation" {
  for_each = var.gateway_domain != "" ? {
    for o in aws_acm_certificate.gateway[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Deliberately no aws_acm_certificate_validation: it would block the apply until the zone is delegated, and delegation is
# done by a person after this apply. The gateway-cert / platform phases wait for ISSUED.
