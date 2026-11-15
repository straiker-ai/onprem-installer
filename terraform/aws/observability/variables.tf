variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name: the add-on's cluster, the Container Insights dimension and the prefix of every resource here."
  type        = string
}

variable "cloudwatch_addon_version" {
  description = "amazon-cloudwatch-observability add-on version (e.g. \"v7.0.1-eksbuild.1\"). null = the default version EKS offers for the cluster's Kubernetes version."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of the Container Insights log groups (/aws/containerinsights/<cluster>/{application,dataplane,host,performance}) in days."
  type        = number
  default     = 30
}

variable "alarm_emails" {
  description = "E-mail addresses subscribed to the alarm topic. Each must confirm AWS's subscription mail before it receives alarms."
  type        = list(string)
  default     = []
}

variable "alb_arn_suffix" {
  description = "The edge ALB's ARN suffix (\"app/<name>/<id>\", the LoadBalancer metric dimension). Empty = no ALB alarms (edge types without an ALB)."
  type        = string
  default     = ""
}

variable "aurora_cluster_ids" {
  description = "Aurora cluster identifiers to alarm on (CPU and Serverless v2 capacity)."
  type        = list(string)
  default     = []
}

variable "alarms" {
  description = <<-EOT
    Extra CloudWatch alarms keyed by stable name (alarm "<cluster>-<key>"), all sent to the alarm topic. A key equal to
    a built-in alarm's (alarms.tf: nodes-failed, nodes-cpu-high, nodes-memory-high, alb-5xx, alb-target-5xx,
    aurora-<id>-cpu, aurora-<id>-acu) replaces it.
  EOT
  type = map(object({
    description         = string
    namespace           = string
    metric_name         = string
    dimensions          = map(string)
    statistic           = string
    comparison_operator = string
    threshold           = number
    period              = optional(number, 300)
    evaluation_periods  = optional(number, 3)
  }))
  default = {}
}
