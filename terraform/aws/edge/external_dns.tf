# IAM for ExternalDNS (see install-straiker.sh's phase_external_dns, which
# installs the controller itself via Helm using this role through Pod
# Identity) — only for edgeType=xalb with Route53 automation opted into via
# --xalb-route53 (off by default; gated together with route53.tf's
# DNS-validated certificate, since both need the same zone access — when
# off, xalb requires an explicit --alb-certificate-arn instead, same as alb).
# Policy is AWS's own documented minimal ExternalDNS policy (small enough
# to embed via jsonencode directly, unlike alb_controller.tf's much larger
# third-party policy which is kept as a separate file for upstream diffing).
resource "aws_iam_role" "external_dns" {
  count = var.enable_route53_automation ? 1 : 0
  name  = "${var.prefix}-external-dns"

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

resource "aws_iam_role_policy" "external_dns" {
  count = var.enable_route53_automation ? 1 : 0
  name  = "external-dns"
  role  = aws_iam_role.external_dns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResources"
        ]
        Resource = ["arn:aws:route53:::hostedzone/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count = var.enable_route53_automation ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.external_dns_namespace
  service_account = var.external_dns_service_account_name
  role_arn        = aws_iam_role.external_dns[0].arn

  tags = local.common_tags
}
