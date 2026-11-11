resource "aws_kms_key" "this" {
  for_each = var.kms_keys

  description             = coalesce(each.value.description, "${local.name} ${each.key}")
  deletion_window_in_days = each.value.deletion_window_in_days
  enable_key_rotation     = each.value.enable_key_rotation

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}" })
}

resource "aws_kms_alias" "this" {
  for_each = var.kms_keys

  name          = "alias/${local.name}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
