# Separate from the hauler role: this is for the actual inference/model-serving
# workload (straiker-platform, not yet in this repo) to read synced models back
# out of S3 — read-only, and never needs ECR (nodes pull images, not pods).
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

# Only bind once the workload's namespace/service account are known — straiker-
# platform isn't in this repo yet, so leave this a no-op until they're supplied.
resource "aws_eks_pod_identity_association" "workload" {
  count = (var.workload_namespace != "" && var.workload_service_account_name != "") ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.workload_namespace
  service_account = var.workload_service_account_name
  role_arn        = aws_iam_role.workload.arn

  tags = local.common_tags
}
