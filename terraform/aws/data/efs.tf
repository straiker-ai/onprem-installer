resource "aws_security_group" "efs" {
  for_each = var.efs_file_systems

  name        = "${local.name}-${each.key}-efs"
  description = "EFS ${local.name}-${each.key} (NFS 2049)"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  efs_cidr_rules = merge([
    for name, _ in var.efs_file_systems : { for cidr in local.client_cidrs : "${name}/${cidr}" => { fs = name, cidr = cidr } }
  ]...)
  efs_sg_rules = merge([
    for name, _ in var.efs_file_systems : { for sg in local.client_sgs : "${name}/${sg}" => { fs = name, sg = sg } }
  ]...)
  efs_mount_targets = merge([
    for name, _ in var.efs_file_systems : { for az, subnet in local.subnet_by_az : "${name}/${az}" => { fs = name, subnet = subnet } }
  ]...)
}

resource "aws_vpc_security_group_ingress_rule" "efs_cidr" {
  for_each = local.efs_cidr_rules

  security_group_id = aws_security_group.efs[each.value.fs].id
  description       = "NFS from ${each.value.cidr}"
  ip_protocol       = "tcp"
  from_port         = 2049
  to_port           = 2049
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "efs_sg" {
  for_each = local.efs_sg_rules

  security_group_id            = aws_security_group.efs[each.value.fs].id
  description                  = "NFS"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = each.value.sg
}

resource "aws_efs_file_system" "this" {
  for_each = var.efs_file_systems

  creation_token   = "${local.name}-${each.key}"
  encrypted        = true
  kms_key_id       = local.kms_key_arn
  performance_mode = each.value.performance_mode
  throughput_mode  = each.value.throughput_mode

  provisioned_throughput_in_mibps = each.value.throughput_mode == "provisioned" ? each.value.provisioned_throughput_in_mibps : null

  dynamic "lifecycle_policy" {
    for_each = each.value.transition_to_ia != null ? [1] : []
    content {
      transition_to_ia = each.value.transition_to_ia
    }
  }

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}" })
}

resource "aws_efs_mount_target" "this" {
  for_each = local.efs_mount_targets

  file_system_id  = aws_efs_file_system.this[each.value.fs].id
  subnet_id       = each.value.subnet
  security_groups = [aws_security_group.efs[each.value.fs].id]
}
