# IAM for the OpenTelemetry collector (charts/straiker-otel): X-Ray for traces, CloudWatch metrics + Logs (EMF) for metrics.
# Opt-in (enable_otel); the association needs the EKS Pod Identity agent, which this phase already requires.

data "aws_iam_policy_document" "otel_assume" {
  count = var.enable_otel ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "otel" {
  count = var.enable_otel ? 1 : 0

  name               = "${var.cluster_name}-otel-collector"
  assume_role_policy = data.aws_iam_policy_document.otel_assume[0].json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "otel" {
  count = var.enable_otel ? 1 : 0

  statement {
    sid = "XRay"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid = "EmfLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
    ]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/straiker/${var.cluster_name}/*"]
  }
}

resource "aws_iam_role_policy" "otel" {
  count = var.enable_otel ? 1 : 0

  name   = "otel-collector"
  role   = aws_iam_role.otel[0].id
  policy = data.aws_iam_policy_document.otel[0].json
}

resource "aws_eks_pod_identity_association" "otel" {
  count = var.enable_otel ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.otel_namespace
  service_account = var.otel_service_account
  role_arn        = aws_iam_role.otel[0].arn
}
