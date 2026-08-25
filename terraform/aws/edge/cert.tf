# Temporary bootstrap certificate for edgeType=alb installs that don't have
# a real one yet. The customer/SE swaps in a real certificate later with:
#   aws acm import-certificate --certificate-arn <this-arn> \
#     --certificate file://real-cert.pem --private-key file://real-key.pem
# — same ARN, no re-apply needed, so charts/straiker-edge's Ingress (which
# references this ARN, not its content) needs no changes either.
#
# ignore_changes is load-bearing: without it, the next `tofu apply` touching
# this state would see the customer's real cert as drift against the
# self-signed values below and plan to revert it.
resource "tls_private_key" "self_signed" {
  count     = var.enable_self_signed_cert ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count           = var.enable_self_signed_cert ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name = length(var.san_hostnames) > 0 ? var.san_hostnames[0] : "straiker.internal"
  }
  dns_names             = var.san_hostnames
  validity_period_hours = 24 * 365
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "self_signed" {
  count            = var.enable_self_signed_cert ? 1 : 0
  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  lifecycle {
    ignore_changes = [private_key, certificate_body, certificate_chain]
  }

  tags = merge(local.common_tags, { Name = "${var.prefix}-alb-temp-self-signed" })
}
