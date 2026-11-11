# MSK Serverless: SASL/IAM only, port 9098. The platform services (shared/eventbus)
# authenticate with aws_msk_iam through Pod Identity; no secrets involved.

resource "aws_security_group" "msk" {
  for_each = var.msk_clusters

  name        = "${local.name}-${each.key}-msk"
  description = "MSK Serverless ${local.name}-${each.key} (SASL/IAM, 9098)"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}-msk" })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  msk_cidr_rules = merge([
    for name, _ in var.msk_clusters : { for cidr in local.client_cidrs : "${name}/${cidr}" => { cluster = name, cidr = cidr } }
  ]...)
  msk_sg_rules = merge([
    for name, _ in var.msk_clusters : { for sg in local.client_sgs : "${name}/${sg}" => { cluster = name, sg = sg } }
  ]...)
}

resource "aws_vpc_security_group_ingress_rule" "msk_cidr" {
  for_each = local.msk_cidr_rules

  security_group_id = aws_security_group.msk[each.value.cluster].id
  description       = "Kafka SASL/IAM from ${each.value.cidr}"
  ip_protocol       = "tcp"
  from_port         = 9098
  to_port           = 9098
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "msk_sg" {
  for_each = local.msk_sg_rules

  security_group_id            = aws_security_group.msk[each.value.cluster].id
  description                  = "Kafka SASL/IAM"
  ip_protocol                  = "tcp"
  from_port                    = 9098
  to_port                      = 9098
  referenced_security_group_id = each.value.sg
}

resource "aws_vpc_security_group_egress_rule" "msk" {
  for_each = var.msk_clusters

  security_group_id = aws_security_group.msk[each.key].id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_msk_serverless_cluster" "this" {
  for_each = var.msk_clusters

  cluster_name = "${local.name}-${each.key}"

  vpc_config {
    subnet_ids         = slice(values(local.subnet_by_az), 0, min(3, length(local.subnet_by_az))) # distinct AZs, 2-3 as MSK Serverless requires
    security_group_ids = [aws_security_group.msk[each.key].id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}" })
}
