output "alarm_topic_arn" {
  value       = aws_sns_topic.alarms.arn
  description = "SNS topic every alarm notifies (subscribe more endpoints to it)."
}

output "alarm_names" {
  value       = sort([for a in aws_cloudwatch_metric_alarm.this : a.alarm_name])
  description = "CloudWatch alarms created."
}

output "container_log_groups" {
  value       = sort([for g in aws_cloudwatch_log_group.container_insights : g.name])
  description = "CloudWatch Logs groups with the cluster's container, node and performance logs."
}
