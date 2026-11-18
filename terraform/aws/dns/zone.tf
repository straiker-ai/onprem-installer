# The public hosted zone of the install's base domain (opt-in via --create-zone). prevent_destroy: deleting it would
# break the delegation from the parent zone; this stack is deliberately not part of the --destroy-eks teardown.
resource "aws_route53_zone" "this" {
  count = var.create_zone ? 1 : 0

  name    = var.domain
  comment = "Straiker on-prem install ${var.cluster_name}"

  tags = merge(local.common_tags, { Name = var.domain })

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_route53_zone" "existing" {
  count = !var.create_zone && var.gateway_domain != "" ? 1 : 0

  name         = var.domain
  private_zone = false
}
