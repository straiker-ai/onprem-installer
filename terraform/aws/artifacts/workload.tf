# Separate from the hauler role: this is for the actual inference/model-serving
# workload (charts/straiker-inference's "straiker-inference" ServiceAccount) to
# read synced models back out of S3 — read-only, and never needs ECR (nodes
# pull images, not pods).
resource "aws_iam_role" "workload" {
  name = "${var.prefix}-models-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "workload_s3_read" {
  name = "models-bucket-read"
  role = aws_iam_role.workload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.models.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.models.arn}/*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = var.workload_namespace != "" ? toset(var.workload_service_account_names) : toset([])

  cluster_name    = var.cluster_name
  namespace       = var.workload_namespace
  service_account = each.value
  role_arn        = aws_iam_role.workload.arn

  tags = local.common_tags
}

# ── Bedrock Pod Identity ──────────────────────────────────────────────────────
# Only created when bedrock_mode=true (AI_PROVIDER_MODE=bedrock). Gives
# bifrost's own ServiceAccount permission to call Bedrock without static keys.
resource "aws_iam_role" "bifrost_bedrock" {
  count = var.bedrock_mode ? 1 : 0
  name  = "${var.prefix}-bifrost-bedrock"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "bifrost_bedrock_invoke" {
  count = var.bedrock_mode ? 1 : 0
  name  = "bedrock-invoke"
  role  = aws_iam_role.bifrost_bedrock[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        # foundation-model/* alone 403s any cross-region inference profile invocation
        # (e.g. "global.anthropic.claude-*", the model form the deployed models
        # actually use for Bedrock's global/us/eu/jp/apac routing) - confirmed live via
        # a direct InvokeModel call denied on
        # "arn:aws:bedrock:<region>:<account>:inference-profile/<id>", a distinct
        # resource type from foundation-model that needs its own grant.
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*"
        ]
      },
      {
        Effect = "Allow"
        # Bifrost's own startup self-check (list-models, used for its UI/model catalog) -
        # not resource-scopable, so a separate statement with Resource "*".
        Action   = ["bedrock:ListFoundationModels"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "bifrost_bedrock" {
  count = var.bedrock_mode && var.workload_namespace != "" ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.workload_namespace
  service_account = var.bifrost_service_account_name
  role_arn        = aws_iam_role.bifrost_bedrock[0].arn

  tags = local.common_tags
}
