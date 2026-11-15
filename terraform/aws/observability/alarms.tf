# CloudWatch alarms -> SNS topic "<cluster>-alarms" (e-mail subscribers from var.alarm_emails; each address gets an
# AWS confirmation mail and receives nothing until it is confirmed).
#
# The built-in alarms below are keyed by stable name; var.alarms adds alarms or overrides a built-in one by using its
# key (e.g. a different threshold). Alarms whose resource is not installed (no ALB, no Aurora) are left out.
# The topic is not KMS-encrypted on purpose: CloudWatch cannot publish to a topic encrypted with the AWS-managed
# aws/sns key, and alarm messages carry no secrets.

locals {
  ci_dims = { ClusterName = var.cluster_name }

  builtin_alarms = merge(
    {
      "nodes-failed" = {
        description         = "EKS nodes in a failed state (Container Insights)"
        namespace           = "ContainerInsights"
        metric_name         = "cluster_failed_node_count"
        dimensions          = local.ci_dims
        statistic           = "Maximum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        period              = 300
        evaluation_periods  = 3
      }
      "nodes-cpu-high" = {
        description         = "Average node CPU above 85% for 15 minutes"
        namespace           = "ContainerInsights"
        metric_name         = "node_cpu_utilization"
        dimensions          = local.ci_dims
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 85
        period              = 300
        evaluation_periods  = 3
      }
      "nodes-memory-high" = {
        description         = "Average node memory above 90% for 15 minutes"
        namespace           = "ContainerInsights"
        metric_name         = "node_memory_utilization"
        dimensions          = local.ci_dims
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 90
        period              = 300
        evaluation_periods  = 3
      }
    },
    var.alb_arn_suffix == "" ? {} : {
      "alb-5xx" = {
        description         = "Edge ALB returned more than 25 of its own 5xx in 5 minutes (no healthy target, timeouts)"
        namespace           = "AWS/ApplicationELB"
        metric_name         = "HTTPCode_ELB_5XX_Count"
        dimensions          = { LoadBalancer = var.alb_arn_suffix }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 25
        period              = 300
        evaluation_periods  = 1
      }
      "alb-target-5xx" = {
        description         = "Straiker services behind the edge ALB returned more than 50 5xx in 5 minutes"
        namespace           = "AWS/ApplicationELB"
        metric_name         = "HTTPCode_Target_5XX_Count"
        dimensions          = { LoadBalancer = var.alb_arn_suffix }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 50
        period              = 300
        evaluation_periods  = 1
      }
    },
    merge([for id in var.aurora_cluster_ids : {
      "aurora-${id}-cpu" = {
        description         = "Aurora ${id}: CPU above 80% for 15 minutes"
        namespace           = "AWS/RDS"
        metric_name         = "CPUUtilization"
        dimensions          = { DBClusterIdentifier = id }
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 80
        period              = 300
        evaluation_periods  = 3
      }
      "aurora-${id}-acu" = {
        description         = "Aurora ${id}: Serverless v2 capacity above 90% of its maximum ACUs for 15 minutes"
        namespace           = "AWS/RDS"
        metric_name         = "ACUUtilization"
        dimensions          = { DBClusterIdentifier = id }
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 90
        period              = 300
        evaluation_periods  = 3
      }
    }]...),
  )

  alarms = merge(local.builtin_alarms, var.alarms)
}

resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_emails)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  comparison_operator = each.value.comparison_operator
  threshold           = each.value.threshold
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}
