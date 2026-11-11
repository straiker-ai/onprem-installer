# Amazon OpenSearch Service domains (SaaS: platform/opensearch/tf): VPC domain, fine-grained access control
# with an internal master user, encryption at rest + node-to-node, HTTPS only.

data "aws_partition" "current" {}

locals {
  os_az_count = min(3, length(local.azs))

  # Defaults by provision_strategy (SaaS Frankfurt shape for ha/max); per-domain values override.
  os_defaults = {
    min = { instance_type = "t3.small.search", instance_count = 1, master_type = null, az_count = 1, volume_size = 20 }
    ha  = { instance_type = "r7g.large.search", instance_count = 3, master_type = "m7g.large.search", az_count = local.os_az_count, volume_size = 100 }
    max = { instance_type = "r7g.xlarge.search", instance_count = 3, master_type = "m7g.large.search", az_count = local.os_az_count, volume_size = 200 }
  }
  os_default = local.os_defaults[var.provision_strategy]

  opensearch = {
    for k, d in var.opensearch_domains : k => {
      domain_name    = k == "main" ? "${local.name}-oss" : "${local.name}-oss-${k}"
      instance_type  = coalesce(d.instance_type, local.os_default.instance_type)
      instance_count = coalesce(d.instance_count, local.os_default.instance_count)
      master_type    = d.dedicated_master_type != null ? d.dedicated_master_type : local.os_default.master_type
      az_count       = coalesce(d.availability_zone_count, local.os_default.az_count)
      volume_size    = coalesce(d.volume_size, local.os_default.volume_size)
      burstable      = can(regex("^t[23]\\.", coalesce(d.instance_type, local.os_default.instance_type)))
    }
  }

  os_cidr_rules = merge([
    for name, _ in var.opensearch_domains : { for cidr in local.client_cidrs : "${name}/${cidr}" => { domain = name, cidr = cidr } }
  ]...)
  os_sg_rules = merge([
    for name, _ in var.opensearch_domains : { for sg in local.client_sgs : "${name}/${sg}" => { domain = name, sg = sg } }
  ]...)
}

resource "aws_iam_service_linked_role" "opensearch" {
  count            = var.create_opensearch_service_linked_role && length(var.opensearch_domains) > 0 ? 1 : 0
  aws_service_name = "opensearchservice.amazonaws.com"
}

resource "aws_security_group" "opensearch" {
  for_each = var.opensearch_domains

  name        = local.opensearch[each.key].domain_name
  description = "OpenSearch domain ${local.opensearch[each.key].domain_name}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, each.value.tags, { Name = local.opensearch[each.key].domain_name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_cidr" {
  for_each = local.os_cidr_rules

  security_group_id = aws_security_group.opensearch[each.value.domain].id
  description       = "HTTPS from ${each.value.cidr}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_sg" {
  for_each = local.os_sg_rules

  security_group_id            = aws_security_group.opensearch[each.value.domain].id
  description                  = "HTTPS from client security group"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = each.value.sg
}

# Needs upper, lower, digit and a special character (OpenSearch's master password policy).
resource "random_password" "opensearch_master" {
  for_each = var.opensearch_domains

  length           = 32
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_opensearch_domain" "this" {
  for_each = var.opensearch_domains

  domain_name    = local.opensearch[each.key].domain_name
  engine_version = each.value.engine_version

  # Anyone in the VPC may call the domain; fine-grained access control decides what they can do (as SaaS).
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "es:*"
      Resource  = "arn:${data.aws_partition.current.partition}:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.opensearch[each.key].domain_name}/*"
    }]
  })

  cluster_config {
    instance_type            = local.opensearch[each.key].instance_type
    instance_count           = local.opensearch[each.key].instance_count
    dedicated_master_enabled = local.opensearch[each.key].master_type != null
    dedicated_master_type    = local.opensearch[each.key].master_type
    dedicated_master_count   = local.opensearch[each.key].master_type != null ? each.value.dedicated_master_count : null
    zone_awareness_enabled   = local.opensearch[each.key].az_count > 1
    # Standby needs 3 AZs and dedicated masters (SaaS runs it).
    multi_az_with_standby_enabled = local.opensearch[each.key].az_count == 3 && local.opensearch[each.key].master_type != null

    dynamic "zone_awareness_config" {
      for_each = local.opensearch[each.key].az_count > 1 ? [1] : []
      content {
        availability_zone_count = local.opensearch[each.key].az_count
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    # Burstable (t3) instances: gp2; the rest gp3 as SaaS.
    volume_type = local.opensearch[each.key].burstable ? "gp2" : "gp3"
    volume_size = local.opensearch[each.key].volume_size
  }

  vpc_options {
    subnet_ids         = slice(values(local.subnet_by_az), 0, local.opensearch[each.key].az_count)
    security_group_ids = [aws_security_group.opensearch[each.key].id]
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = local.kms_key_arn
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = each.value.master_user_name
      master_user_password = random_password.opensearch_master[each.key].result
    }
  }

  advanced_options = {
    "indices.fielddata.cache.size"        = "20"
    "indices.query.bool.max_clause_count" = "1024"
  }

  # Burstable (t2/t3) instances support neither Auto-Tune nor off-peak windows (the API rejects them).
  auto_tune_options {
    desired_state       = local.opensearch[each.key].burstable ? "DISABLED" : "ENABLED"
    rollback_on_disable = "NO_ROLLBACK"
    use_off_peak_window = false
  }

  dynamic "off_peak_window_options" {
    for_each = local.opensearch[each.key].burstable ? [] : [1]
    content {
      enabled = true
      off_peak_window {
        window_start_time {
          hours   = 0
          minutes = 0
        }
      }
    }
  }

  software_update_options {
    auto_software_update_enabled = false
  }

  tags = merge(local.common_tags, each.value.tags, { Name = local.opensearch[each.key].domain_name })

  depends_on = [aws_iam_service_linked_role.opensearch]

  lifecycle {
    # The master user is only set at creation (OpenSearch doesn't return it); rotate it with the secret's owner tooling.
    ignore_changes = [advanced_security_options[0].master_user_options]
  }
}

resource "aws_secretsmanager_secret" "opensearch" {
  for_each = var.opensearch_domains

  name                    = "${local.name}/opensearch/${each.key}"
  description             = "${local.opensearch[each.key].domain_name} master login and endpoint"
  kms_key_id              = local.kms_key_arn
  recovery_window_in_days = each.value.secret_recovery_window

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}/opensearch/${each.key}" })
}

resource "aws_secretsmanager_secret_version" "opensearch" {
  for_each = var.opensearch_domains

  secret_id = aws_secretsmanager_secret.opensearch[each.key].id
  secret_string = jsonencode({
    username = each.value.master_user_name
    password = random_password.opensearch_master[each.key].result
    endpoint = aws_opensearch_domain.this[each.key].endpoint
    url      = "https://${aws_opensearch_domain.this[each.key].endpoint}"
  })
}
