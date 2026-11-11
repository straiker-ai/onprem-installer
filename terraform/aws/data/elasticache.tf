resource "aws_security_group" "cache" {
  for_each = var.caches

  name        = "${local.name}-${each.key}-cache"
  description = "ElastiCache Serverless ${local.name}-${each.key}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}-cache" })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  cache_cidr_rules = merge([
    for name, _ in var.caches : { for cidr in local.client_cidrs : "${name}/${cidr}" => { cache = name, cidr = cidr } }
  ]...)
  cache_sg_rules = merge([
    for name, _ in var.caches : { for sg in local.client_sgs : "${name}/${sg}" => { cache = name, sg = sg } }
  ]...)
}

resource "aws_vpc_security_group_ingress_rule" "cache_cidr" {
  for_each = local.cache_cidr_rules

  security_group_id = aws_security_group.cache[each.value.cache].id
  description       = "Cache clients from ${each.value.cidr} (primary 6379, reader 6380)"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6380
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "cache_sg" {
  for_each = local.cache_sg_rules

  security_group_id            = aws_security_group.cache[each.value.cache].id
  description                  = "Cache clients (primary 6379, reader 6380)"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6380
  referenced_security_group_id = each.value.sg
}

resource "aws_elasticache_serverless_cache" "this" {
  for_each = var.caches

  name = "${local.name}-${each.key}"
  # Never send "": AWS stores a blank description as " ", which the provider rejects
  # as an inconsistent apply result.
  description          = each.value.description != "" ? each.value.description : "ElastiCache Serverless ${local.name}-${each.key}"
  engine               = each.value.engine
  major_engine_version = each.value.major_engine_version
  subnet_ids           = values(local.subnet_by_az)
  security_group_ids   = [aws_security_group.cache[each.key].id]
  kms_key_id           = local.kms_key_arn

  snapshot_retention_limit = each.value.snapshot_retention_limit

  dynamic "cache_usage_limits" {
    for_each = each.value.max_data_storage_gb != null || each.value.max_ecpu_per_second != null ? [1] : []
    content {
      dynamic "data_storage" {
        for_each = each.value.max_data_storage_gb != null ? [1] : []
        content {
          maximum = each.value.max_data_storage_gb
          unit    = "GB"
        }
      }
      dynamic "ecpu_per_second" {
        for_each = each.value.max_ecpu_per_second != null ? [1] : []
        content {
          maximum = each.value.max_ecpu_per_second
        }
      }
    }
  }

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}" })
}
