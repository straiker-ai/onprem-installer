# IAM role for the in-cluster hauling Jobs (image-mirror + model-sync). Trust is
# scoped to EKS Pod Identity generically (pods.eks.amazonaws.com), not a specific
# cluster's OIDC provider — the pod_identity_association below is what actually
# binds it to var.cluster_name, so this works identically whether we provisioned
# that cluster ourselves or the customer brought their own (as long as it has the
# EKS Pod Identity Agent addon installed).
resource "aws_iam_role" "hauler" {
  name = "${var.prefix}-artifact-hauler"

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

# Wildcard-scoped to all repos under this account/region rather than the specific
# repos in aws_ecr_repository.mirror — keeps this valid even when image_names is
# empty (an empty Resource list is rejected by IAM), and this is the customer's
# own account, not a shared one.
resource "aws_iam_role_policy" "hauler_ecr" {
  name = "ecr-push"
  role = aws_iam_role.hauler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "hauler_s3" {
  name = "models-bucket-write"
  role = aws_iam_role.hauler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.models.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = ["${aws_s3_bucket.models.arn}/*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "hauler" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.hauler.arn

  tags = local.common_tags
}
