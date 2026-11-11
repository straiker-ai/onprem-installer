locals {
  aurora_enabled  = var.aurora.enabled
  aurora_clusters = local.aurora_enabled ? var.aurora_clusters : {}

  # The first cluster ever created here is "platform" and keeps its original
  # identifiers (<cluster>-aurora, ...) so adding more clusters never replaces it.
  aurora_ids = {
    for k, _ in local.aurora_clusters :
    k => k == "platform" ? "${local.name}-aurora" : "${local.name}-aurora-${k}"
  }

  # Instances of every cluster, flattened to "<cluster>/<instance>". Normalized to a
  # fixed object shape: the raw map literal mixes string/number/null values, and HCL
  # would coerce them to one type (promotion_tier -> string), and an empty {} misses
  # the variable's attribute defaults. try() supplies every default.
  aurora_instances = merge([
    for ck, c in local.aurora_clusters : {
      for ik, iv in coalesce(c.instances, { "writer-1" = {}, "reader-1" = {} }) :
      "${ck}/${ik}" => {
        cluster           = ck
        name              = ik
        instance_class    = try(iv.instance_class, "db.serverless")
        availability_zone = try(iv.availability_zone, null)
        promotion_tier    = try(iv.promotion_tier, 1)
      }
    }
  ]...)

  # Ingress rule keys: the "platform" cluster keeps its original bare keys (no rule is
  # recreated when the clusters were split); other clusters are prefixed.
  aurora_cidr_rules = {
    for p in setproduct(keys(local.aurora_clusters), local.client_cidrs) :
    (p[0] == "platform" ? p[1] : "${p[0]}/${p[1]}") => { cluster = p[0], cidr = p[1] }
  }
  aurora_sg_rules = {
    for p in setproduct(keys(local.aurora_clusters), tolist(local.client_sgs)) :
    (p[0] == "platform" ? p[1] : "${p[0]}/${p[1]}") => { cluster = p[0], sg = p[1] }
  }
}

# Enhanced Monitoring role, as the SaaS clusters have it (<cluster>-rds-monitoring-role).
data "aws_iam_policy_document" "aurora_monitoring_assume" {
  count = local.aurora_enabled && var.aurora.monitoring_interval > 0 ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aurora_monitoring" {
  count = local.aurora_enabled && var.aurora.monitoring_interval > 0 ? 1 : 0

  name               = "${local.name}-rds-monitoring-role"
  assume_role_policy = data.aws_iam_policy_document.aurora_monitoring_assume[0].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "aurora_monitoring" {
  count = local.aurora_enabled && var.aurora.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.aurora_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# The single cluster from before aurora_clusters existed is now the "platform" entry.
moved {
  from = aws_db_subnet_group.aurora[0]
  to   = aws_db_subnet_group.aurora["platform"]
}
moved {
  from = aws_security_group.aurora[0]
  to   = aws_security_group.aurora["platform"]
}
moved {
  from = aws_rds_cluster_parameter_group.aurora[0]
  to   = aws_rds_cluster_parameter_group.aurora["platform"]
}
moved {
  from = aws_rds_cluster.aurora[0]
  to   = aws_rds_cluster.aurora["platform"]
}
moved {
  from = aws_rds_cluster_instance.aurora_writer["writer-1"]
  to   = aws_rds_cluster_instance.aurora_writer["platform/writer-1"]
}
moved {
  from = aws_rds_cluster_instance.aurora_reader["reader-1"]
  to   = aws_rds_cluster_instance.aurora_reader["platform/reader-1"]
}

resource "aws_db_subnet_group" "aurora" {
  for_each = local.aurora_clusters

  name        = "${local.aurora_ids[each.key]}-subnets"
  description = "Subnets of ${local.aurora_ids[each.key]}"
  subnet_ids  = values(local.subnet_by_az)

  tags = merge(local.common_tags, { Name = "${local.aurora_ids[each.key]}-subnets" })
}

resource "aws_security_group" "aurora" {
  for_each = local.aurora_clusters

  name        = "${local.aurora_ids[each.key]}-sg"
  description = "Access to Aurora cluster ${local.aurora_ids[each.key]}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.aurora_ids[each.key]}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "aurora_cidr" {
  for_each = local.aurora_cidr_rules

  security_group_id = aws_security_group.aurora[each.value.cluster].id
  description       = "PostgreSQL from ${each.value.cidr}"
  ip_protocol       = "tcp"
  from_port         = var.aurora.port
  to_port           = var.aurora.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "aurora_sg" {
  for_each = local.aurora_sg_rules

  security_group_id            = aws_security_group.aurora[each.value.cluster].id
  description                  = "PostgreSQL from ${each.value.sg}"
  ip_protocol                  = "tcp"
  from_port                    = var.aurora.port
  to_port                      = var.aurora.port
  referenced_security_group_id = each.value.sg
}

resource "aws_rds_cluster_parameter_group" "aurora" {
  for_each = length(var.aurora.parameters) > 0 ? local.aurora_clusters : {}

  name        = "${local.aurora_ids[each.key]}-pg"
  family      = var.aurora.parameter_group_family
  description = "Cluster parameters of ${local.aurora_ids[each.key]}"

  dynamic "parameter" {
    for_each = var.aurora.parameters
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = merge(local.common_tags, { Name = "${local.aurora_ids[each.key]}-pg" })
}

resource "aws_rds_cluster" "aurora" {
  for_each = local.aurora_clusters

  cluster_identifier = local.aurora_ids[each.key]
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned" # Serverless v2 runs on provisioned clusters
  engine_version     = var.aurora.engine_version
  port               = var.aurora.port

  master_username               = var.aurora.master_username
  manage_master_user_password   = true # password in Secrets Manager, rotated by RDS
  master_user_secret_kms_key_id = local.kms_key_arn

  db_subnet_group_name            = aws_db_subnet_group.aurora[each.key].name
  vpc_security_group_ids          = [aws_security_group.aurora[each.key].id]
  db_cluster_parameter_group_name = contains(keys(aws_rds_cluster_parameter_group.aurora), each.key) ? aws_rds_cluster_parameter_group.aurora[each.key].name : null

  serverlessv2_scaling_configuration {
    min_capacity = each.value.min_capacity
    max_capacity = each.value.max_capacity
  }

  storage_encrypted = true
  kms_key_id        = local.kms_key_arn

  # Changes (capacity, parameter group) take effect now, not in the next maintenance window.
  apply_immediately            = true
  enable_http_endpoint         = var.aurora.data_api_enabled
  preferred_backup_window      = var.aurora.preferred_backup_window
  preferred_maintenance_window = var.aurora.preferred_maintenance_window

  deletion_protection       = coalesce(var.aurora.deletion_protection, local.ha)
  backup_retention_period   = var.aurora.backup_retention_period
  copy_tags_to_snapshot     = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.aurora_ids[each.key]}-final"

  iam_database_authentication_enabled   = var.aurora.iam_database_authentication_enabled
  performance_insights_enabled          = var.aurora.performance_insights_enabled
  performance_insights_kms_key_id       = var.aurora.performance_insights_enabled ? local.kms_key_arn : null
  performance_insights_retention_period = var.aurora.performance_insights_enabled ? 7 : null

  tags = merge(local.common_tags, { Name = local.aurora_ids[each.key] })

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# Writer first (the instance named "writer-1"), readers after it.
resource "aws_rds_cluster_instance" "aurora_writer" {
  for_each = { for k, v in local.aurora_instances : k => v if v.name == "writer-1" }

  identifier         = "${local.aurora_ids[each.value.cluster]}-${each.value.name}"
  cluster_identifier = aws_rds_cluster.aurora[each.value.cluster].id
  engine             = aws_rds_cluster.aurora[each.value.cluster].engine
  instance_class     = each.value.instance_class
  availability_zone  = each.value.availability_zone
  promotion_tier     = each.value.promotion_tier

  publicly_accessible                   = false
  auto_minor_version_upgrade            = true
  monitoring_interval                   = var.aurora.monitoring_interval
  monitoring_role_arn                   = var.aurora.monitoring_interval > 0 ? aws_iam_role.aurora_monitoring[0].arn : null
  performance_insights_enabled          = var.aurora.performance_insights_enabled
  performance_insights_kms_key_id       = var.aurora.performance_insights_enabled ? local.kms_key_arn : null
  performance_insights_retention_period = var.aurora.performance_insights_enabled ? 7 : null

  tags = merge(local.common_tags, { Name = "${local.aurora_ids[each.value.cluster]}-${each.value.name}" })
}

resource "aws_rds_cluster_instance" "aurora_reader" {
  for_each = { for k, v in local.aurora_instances : k => v if v.name != "writer-1" }

  identifier         = "${local.aurora_ids[each.value.cluster]}-${each.value.name}"
  cluster_identifier = aws_rds_cluster.aurora[each.value.cluster].id
  engine             = aws_rds_cluster.aurora[each.value.cluster].engine
  instance_class     = each.value.instance_class
  # SaaS puts the reader in another AZ than the writer, so a zone failure leaves a promotable
  # reader. Unless pinned, pick the first AZ that is not the writer's (the writer itself is left
  # unpinned, so an existing writer is never replaced).
  availability_zone = coalesce(
    each.value.availability_zone,
    try([for az in local.azs : az if az != aws_rds_cluster_instance.aurora_writer["${each.value.cluster}/writer-1"].availability_zone][0], null)
  )
  promotion_tier = each.value.promotion_tier

  publicly_accessible                   = false
  auto_minor_version_upgrade            = true
  monitoring_interval                   = var.aurora.monitoring_interval
  monitoring_role_arn                   = var.aurora.monitoring_interval > 0 ? aws_iam_role.aurora_monitoring[0].arn : null
  performance_insights_enabled          = var.aurora.performance_insights_enabled
  performance_insights_kms_key_id       = var.aurora.performance_insights_enabled ? local.kms_key_arn : null
  performance_insights_retention_period = var.aurora.performance_insights_enabled ? 7 : null

  tags = merge(local.common_tags, { Name = "${local.aurora_ids[each.value.cluster]}-${each.value.name}" })

  depends_on = [aws_rds_cluster_instance.aurora_writer]
}
