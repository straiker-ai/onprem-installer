# Amazon CloudWatch Observability EKS add-on: Container Insights (enhanced) metrics for nodes, pods and GPUs
# (DCGM exporter on the GPU nodes), and every container's stdout/stderr in CloudWatch Logs through Fluent Bit.
# Runs on every node, tainted pools included (the add-on's default toleration is "Exists").
#
# Application Signals is switched OFF: its default auto-monitor instruments every Java/Python/Node/.NET Deployment
# with an OpenTelemetry agent on its next restart, which would change how the Straiker services run.
#
# Auth: Pod Identity for the add-on's ServiceAccount amazon-cloudwatch/cloudwatch-agent (the cluster's
# eks-pod-identity-agent add-on must exist; terraform/aws/eks installs it).

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_agent" {
  name               = "${local.name}-cloudwatch-agent"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = local.container_insights_log_groups

  name              = "/aws/containerinsights/${var.cluster_name}/${each.key}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name  = var.cluster_name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = var.cloudwatch_addon_version

  pod_identity_association {
    role_arn        = aws_iam_role.cloudwatch_agent.arn
    service_account = "cloudwatch-agent"
  }

  # system-node-critical: the agents are per-node DaemonSets; on a node already full of workloads (a small Karpenter
  # node) they would otherwise stay Pending and that node would have no metrics or logs.
  configuration_values = jsonencode({
    priorityClassName  = "system-node-critical"
    containerLogs      = { enabled = true }
    applicationSignals = { enabled = false }
    manager = {
      applicationSignals = {
        autoMonitor = { monitorAllServices = false }
      }
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_cloudwatch_log_group.container_insights,
  ]
}
