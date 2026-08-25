# IAM for cert-manager's Route53 DNS-01 solver (see install-straiker.sh's
# phase_cert_manager, which installs cert-manager itself via Helm using
# this role through Pod Identity) -- only for edgeType=tailscale (off by
# default; --edge-type tailscale turns it on). Policy shape mirrors
# external_dns.tf's exactly, just scoped to the one zone this install's
# domain resolves to rather than every zone in the account.
data "aws_route53_zone" "cert_manager" {
  count        = var.enable_cert_manager_route53 ? 1 : 0
  name         = var.domain
  private_zone = false
}

resource "aws_iam_role" "cert_manager" {
  count = var.enable_cert_manager_route53 ? 1 : 0
  name  = "${var.prefix}-cert-manager"

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

resource "aws_iam_role_policy" "cert_manager" {
  count = var.enable_cert_manager_route53 ? 1 : 0
  name  = "cert-manager-route53"
  role  = aws_iam_role.cert_manager[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.cert_manager[0].zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:GetChange"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  count = var.enable_cert_manager_route53 ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.cert_manager_namespace
  service_account = var.cert_manager_service_account_name
  role_arn        = aws_iam_role.cert_manager[0].arn

  tags = local.common_tags
}
