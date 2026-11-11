# DynamoDB tables (the api-gateway's environment table). Schema mirrors SaaS
# platform/cognito-environment-api: pk/sk plus the apiKey-index GSI the gateway queries
# (api key -> straikerId/environmentId). On-prem the installer seeds the first environment.

resource "aws_dynamodb_table" "this" {
  for_each = var.dynamodb_tables

  name                        = "${local.name}-${each.key}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = coalesce(each.value.deletion_protection, local.ha)

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  attribute {
    name = "apiKey"
    type = "S"
  }

  global_secondary_index {
    name               = "apiKey-index"
    hash_key           = "apiKey"
    projection_type    = "INCLUDE"
    non_key_attributes = ["straikerId", "insertionMode", "environmentId"]
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}" })
}
