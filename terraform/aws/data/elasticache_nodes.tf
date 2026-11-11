# Node-based ElastiCache replication groups (SaaS iris-cache shape): Valkey, multi-AZ + automatic
# failover, TLS and AUTH. Serverless caches (elasticache.tf) stay for Defend/Argus.

locals {
  redis_cidr_rules = merge([
    for name, _ in var.redis_replication_groups : { for cidr in local.client_cidrs : "${name}/${cidr}" => { group = name, cidr = cidr } }
  ]...)
  redis_sg_rules = merge([
    for name, _ in var.redis_replication_groups : { for sg in local.client_sgs : "${name}/${sg}" => { group = name, sg = sg } }
  ]...)
}

resource "aws_security_group" "redis" {
  for_each = var.redis_replication_groups

  name        = "${local.name}-${each.key}-redis"
  description = "ElastiCache replication group ${local.name}-${each.key}-redis"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}-redis" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis_cidr" {
  for_each = local.redis_cidr_rules

  security_group_id = aws_security_group.redis[each.value.group].id
  description       = "Redis clients from ${each.value.cidr}"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "redis_sg" {
  for_each = local.redis_sg_rules

  security_group_id            = aws_security_group.redis[each.value.group].id
  description                  = "Redis clients"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = each.value.sg
}

resource "aws_elasticache_subnet_group" "redis" {
  for_each = var.redis_replication_groups

  name       = "${local.name}-${each.key}-redis"
  subnet_ids = values(local.subnet_by_az)
  tags       = merge(local.common_tags, each.value.tags)
}

# Alphanumeric only: ElastiCache restricts AUTH token characters and the value is embedded in a URL.
resource "random_password" "redis_auth" {
  for_each = var.redis_replication_groups

  length  = 48
  special = false
}

resource "aws_elasticache_replication_group" "this" {
  for_each = var.redis_replication_groups

  replication_group_id = "${local.name}-${each.key}-redis"
  description          = "${local.name} ${each.key} cache"
  engine               = "valkey"
  engine_version       = each.value.engine_version
  node_type            = each.value.node_type
  port                 = 6379

  num_cache_clusters         = each.value.num_cache_clusters
  automatic_failover_enabled = each.value.num_cache_clusters > 1
  multi_az_enabled           = each.value.num_cache_clusters > 1

  subnet_group_name  = aws_elasticache_subnet_group.redis[each.key].name
  security_group_ids = [aws_security_group.redis[each.key].id]

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  kms_key_id                 = local.kms_key_arn
  auth_token                 = random_password.redis_auth[each.key].result

  snapshot_retention_limit = each.value.snapshot_retention_limit
  apply_immediately        = true

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}-redis" })
}

resource "aws_secretsmanager_secret" "redis" {
  for_each = var.redis_replication_groups

  name                    = "${local.name}/${each.key}/redis"
  description             = "${local.name} ${each.key} cache connection details"
  kms_key_id              = local.kms_key_arn
  recovery_window_in_days = each.value.secret_recovery_window

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}/${each.key}/redis" })
}

resource "aws_secretsmanager_secret_version" "redis" {
  for_each = var.redis_replication_groups

  secret_id = aws_secretsmanager_secret.redis[each.key].id
  secret_string = jsonencode({
    host       = aws_elasticache_replication_group.this[each.key].primary_endpoint_address
    port       = 6379
    auth_token = random_password.redis_auth[each.key].result
    tls        = true
    url        = "rediss://:${random_password.redis_auth[each.key].result}@${aws_elasticache_replication_group.this[each.key].primary_endpoint_address}:6379"
  })
}
