# AWS backends of the SaaS frontend (Frankfurt/Mumbai build), for new AWS-hosted customers (var.saas_frontend).
# Schema mirrors SaaS platform/cognito-environment-api/tf/dynamodb.tf (environment + guardrail tables, same GSIs)
# and platform/audit-logs (Kinesis stream). Off by default, so existing installs plan no change.

locals {
  saas_frontend = var.saas_frontend != null
  saas_ddb_prot = local.saas_frontend ? coalesce(var.saas_frontend.deletion_protection, local.ha) : false
}

resource "aws_dynamodb_table" "saas_environment" {
  count = local.saas_frontend ? 1 : 0

  name                        = "${local.name}-saas-environment"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = local.saas_ddb_prot

  dynamic "attribute" {
    for_each = {
      pk                = "S"
      sk                = "S"
      apiKey            = "S"
      environmentId     = "N"
      applicationId     = "N"
      dstEntityId       = "S"
      srcEntityId       = "S"
      straikerId        = "N"
      irisApplicationId = "S"
    }
    content {
      name = attribute.key
      type = attribute.value
    }
  }

  global_secondary_index {
    name               = "apiKey-index"
    hash_key           = "apiKey"
    projection_type    = "INCLUDE"
    non_key_attributes = ["straikerId", "insertionMode", "environmentId"]
  }
  global_secondary_index {
    name            = "environmentId-applicationId-index"
    hash_key        = "environmentId"
    range_key       = "applicationId"
    projection_type = "INCLUDE"
    non_key_attributes = [
      "isDefault", "owner", "straikerId", "slack", "name", "applicationType", "entities", "inlets", "outlets",
    ]
  }
  global_secondary_index {
    name            = "environmentId-applicationId-index2"
    hash_key        = "environmentId"
    range_key       = "applicationId"
    projection_type = "ALL"
  }
  global_secondary_index {
    name               = "dstEntityId-srcEntityId-index"
    hash_key           = "dstEntityId"
    range_key          = "srcEntityId"
    projection_type    = "INCLUDE"
    non_key_attributes = ["environmentId", "relationType", "straikerId", "dir"]
  }
  global_secondary_index {
    name            = "straikerId-pk-index"
    hash_key        = "straikerId"
    range_key       = "pk"
    projection_type = "ALL"
  }
  global_secondary_index {
    name            = "straikerId-sk-index"
    hash_key        = "straikerId"
    range_key       = "sk"
    projection_type = "ALL"
  }
  global_secondary_index {
    name            = "byIrisApplicationId"
    hash_key        = "irisApplicationId"
    range_key       = "pk"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "${local.name}-saas-environment" })
}

resource "aws_dynamodb_table" "saas_guardrail" {
  count = local.saas_frontend ? 1 : 0

  name                        = "${local.name}-saas-guardrail"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = local.saas_ddb_prot

  dynamic "attribute" {
    for_each = { pk = "S", sk = "S", type = "S" }
    content {
      name = attribute.key
      type = attribute.value
    }
  }

  global_secondary_index {
    name               = "gsi_pk_type"
    hash_key           = "type"
    projection_type    = "INCLUDE"
    non_key_attributes = ["straikerId", "id", "isGlobal", "data", "targetAppId", "guardrailId"]
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "${local.name}-saas-guardrail" })
}

# Audit events the frontend writes (AUDIT_LOGS_STREAM). Delivery into OpenSearch (Firehose) is a follow-up.
resource "aws_kinesis_stream" "saas_audit" {
  count = local.saas_frontend ? 1 : 0

  name             = "${local.name}-audit-logs"
  retention_period = var.saas_frontend.audit_retention_hours

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  encryption_type = "KMS"
  kms_key_id      = local.kms_key_arn

  tags = merge(local.common_tags, { Name = "${local.name}-audit-logs" })
}
