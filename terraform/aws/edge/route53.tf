# For edgeType=xalb with --xalb-route53 (var.enable_route53_automation,
# opt-in, off by default — alb always requires an explicit
# --alb-certificate-arn instead, no self-signed fallback for either edge
# type): looks up the existing zone for var.domain (must already exist —
# this never creates a zone, and only works when it's in this same AWS
# account) and auto-requests+validates a real ACM certificate via DNS
# validation, using that same zone to create the validation record. Gated
# together with external_dns.tf's ExternalDNS controller IAM role, since
# both need the same zone access.
data "aws_route53_zone" "this" {
  count        = var.enable_route53_automation ? 1 : 0
  name         = var.domain
  private_zone = false
}

resource "aws_acm_certificate" "dns_validated" {
  count                     = var.enable_route53_automation ? 1 : 0
  domain_name               = var.san_hostnames[0]
  subject_alternative_names = slice(var.san_hostnames, 1, length(var.san_hostnames))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_route53_automation ? {
    for dvo in aws_acm_certificate.dns_validated[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "dns_validated" {
  count                   = var.enable_route53_automation ? 1 : 0
  certificate_arn         = aws_acm_certificate.dns_validated[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
