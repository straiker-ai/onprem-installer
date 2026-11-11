data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pod" {
  for_each = var.pod_identities

  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}" })
}

data "aws_iam_policy_document" "pod" {
  for_each = var.pod_identities

  dynamic "statement" {
    for_each = length(each.value.msk_clusters) > 0 ? [1] : []
    content {
      sid       = "MskCluster"
      actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster", "kafka-cluster:AlterCluster"]
      resources = [for k in each.value.msk_clusters : aws_msk_serverless_cluster.this[k].arn]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.msk_clusters) > 0 ? [1] : []
    content {
      sid = "MskTopicsAndGroups"
      actions = [
        "kafka-cluster:*Topic*", "kafka-cluster:ReadData", "kafka-cluster:WriteData",
        "kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup",
      ]
      resources = flatten([
        for k in each.value.msk_clusters : [
          "${replace(aws_msk_serverless_cluster.this[k].arn, ":cluster/", ":topic/")}/*",
          "${replace(aws_msk_serverless_cluster.this[k].arn, ":cluster/", ":group/")}/*",
        ]
      ])
    }
  }

  dynamic "statement" {
    for_each = length(each.value.secret_keys) > 0 || each.value.aurora_master_secret ? [1] : []
    content {
      sid     = "SecretsRead"
      actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = concat(
        [for k in each.value.secret_keys : aws_secretsmanager_secret.this[k].arn],
        each.value.aurora_master_secret ? [for c in aws_rds_cluster.aurora : c.master_user_secret[0].secret_arn] : [],
      )
    }
  }

  dynamic "statement" {
    for_each = length(each.value.s3_read) > 0 ? [1] : []
    content {
      sid       = "S3Read"
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = flatten([for k in each.value.s3_read : [aws_s3_bucket.this[k].arn, "${aws_s3_bucket.this[k].arn}/*"]])
    }
  }

  dynamic "statement" {
    for_each = length(each.value.s3_write) > 0 ? [1] : []
    content {
      sid       = "S3Write"
      actions   = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
      resources = [for k in each.value.s3_write : "${aws_s3_bucket.this[k].arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.secret_prefixes_rw) > 0 ? [1] : []
    content {
      sid = "SecretsManage"
      actions = [
        "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue",
        "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
      ]
      resources = [for p in each.value.secret_prefixes_rw : "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${p}*"]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.secret_prefixes_read) > 0 ? [1] : []
    content {
      sid       = "SecretsReadPrefix"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [for p in each.value.secret_prefixes_read : "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${p}*"]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.dynamodb_query) > 0 ? [1] : []
    content {
      sid       = "DynamoApiKeyIndex"
      actions   = ["dynamodb:Query"]
      resources = [for k in each.value.dynamodb_query : "${aws_dynamodb_table.this[k].arn}/index/apiKey-index"]
    }
  }

  dynamic "statement" {
    for_each = each.value.ses_send ? [1] : []
    content {
      sid       = "SesSend"
      actions   = ["ses:SendEmail", "ses:SendRawEmail"]
      resources = ["arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/*"]
    }
  }

  dynamic "statement" {
    for_each = each.value.assume_roles ? [1] : []
    content {
      sid       = "AssumeRoles"
      actions   = ["sts:AssumeRole"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = each.value.kms_use ? [1] : []
    content {
      sid       = "DataKeyUse"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [local.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "pod" {
  for_each = var.pod_identities

  name   = "data"
  role   = aws_iam_role.pod[each.key].id
  policy = data.aws_iam_policy_document.pod[each.key].json
}

resource "aws_iam_role_policy" "pod_extra" {
  for_each = { for k, v in var.pod_identities : k => v if v.policy_json != null }

  name   = "extra"
  role   = aws_iam_role.pod[each.key].id
  policy = each.value.policy_json
}

resource "aws_eks_pod_identity_association" "pod" {
  for_each = var.pod_identities

  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.pod[each.key].arn

  tags = local.common_tags
}
