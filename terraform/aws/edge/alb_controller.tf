# IAM for the AWS Load Balancer Controller (see install-straiker.sh's
# phase_alb_controller, which installs the actual controller via Helm using
# this role through Pod Identity). Gated on var.enable_alb_controller
# (default true) rather than left unconditional -- this module now also
# runs for EDGE_TYPE=tailscale (for cert_manager.tf's Route53 IAM role
# instead), which has no use for an ALB controller at all.
#
# Policy is AWS's own published document for this controller, kept as a
# separate file (alb_controller_iam_policy.json) matching upstream's own
# filename/shape 1:1 for easy diffing against future AWS updates, rather
# than hand-translated into HCL jsonencode(){} (this policy has 15+
# statements and changes periodically; a literal file() is much lower-risk
# than keeping a manual HCL transcription in sync).
resource "aws_iam_role" "alb_controller" {
  count = var.enable_alb_controller ? 1 : 0
  name  = "${var.prefix}-alb-controller"

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

resource "aws_iam_role_policy" "alb_controller" {
  count  = var.enable_alb_controller ? 1 : 0
  name   = "alb-controller"
  role   = aws_iam_role.alb_controller[0].id
  policy = file("${path.module}/alb_controller_iam_policy.json")
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  count           = var.enable_alb_controller ? 1 : 0
  cluster_name    = var.cluster_name
  namespace       = var.alb_controller_namespace
  service_account = var.alb_controller_service_account_name
  role_arn        = aws_iam_role.alb_controller[0].arn

  tags = local.common_tags
}
