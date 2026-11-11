locals {
  generated_secret_keys = merge([
    for name, s in var.secrets : { for k in s.generated_keys : "${name}/${k}" => { secret = name, key = k, length = s.password_length } }
  ]...)
}

resource "random_password" "generated" {
  for_each = local.generated_secret_keys

  length  = each.value.length
  special = false
}

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name                    = "${local.name}/${each.key}"
  description             = coalesce(each.value.description, "${local.name} ${each.key}")
  kms_key_id              = local.kms_key_arn
  recovery_window_in_days = each.value.recovery_window_in_days

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}/${each.key}" })
}

resource "aws_secretsmanager_secret_version" "generated" {
  for_each = { for name, s in var.secrets : name => s if length(s.generated_keys) > 0 }

  secret_id = aws_secretsmanager_secret.this[each.key].id
  secret_string = jsonencode({
    for k in each.value.generated_keys : k => random_password.generated["${each.key}/${k}"].result
  })

  # Set once; later edits / rotation are not overwritten.
  lifecycle {
    ignore_changes = [secret_string]
  }
}
