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

output "vpc_flow_log_group" {
  description = "CloudWatch Logs group holding the VPC flow logs (empty when not enabled)."
  value       = var.enable_vpc_flow_logs ? aws_cloudwatch_log_group.vpc_flow[0].name : ""
}

output "cloudtrail_bucket" {
  description = "S3 bucket holding the CloudTrail logs (empty when not enabled)."
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail[0].id : ""
}

output "cloudtrail_name" {
  description = "Name of the CloudTrail trail (empty when not enabled)."
  value       = var.enable_cloudtrail ? aws_cloudtrail.this[0].name : ""
}
