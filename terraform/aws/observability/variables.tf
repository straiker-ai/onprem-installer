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

# ---------------------------------------------------------------- Audit (opt-in)

variable "enable_vpc_flow_logs" {
  description = "Record the cluster VPC's network traffic metadata (accepted and rejected connections) in CloudWatch Logs. Off by default: it costs per GB ingested."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC to record when enable_vpc_flow_logs is true (the cluster's VPC)."
  type        = string
  default     = ""
}

variable "flow_log_traffic_type" {
  description = "ALL, ACCEPT or REJECT. REJECT records only refused traffic: far cheaper, and what a security review looks at first."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ALL", "ACCEPT", "REJECT"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be ALL, ACCEPT or REJECT."
  }
}

variable "flow_log_retention_days" {
  description = "Retention of the flow-log group /aws/vpc/<cluster>/flow-logs, in days (a value CloudWatch Logs accepts, e.g. 30, 90, 365)."
  type        = number
  default     = 90
}

variable "enable_cloudtrail" {
  description = "Create a CloudTrail trail for this install's account and region (management events) with its own encrypted, private S3 bucket. Off by default: skip it when the account or AWS Organization already has a trail covering it (a second trail is billed)."
  type        = bool
  default     = false
}

variable "cloudtrail_multi_region" {
  description = "Record every region, not just this one. Leave false when an organization trail already covers the other regions."
  type        = bool
  default     = false
}

variable "cloudtrail_include_global_events" {
  description = "Include global service events (IAM, STS, CloudFront). Turn on in exactly one trail of the account to avoid paying for duplicates."
  type        = bool
  default     = true
}

variable "cloudtrail_retention_days" {
  description = "Days the trail's log files are kept in S3 before they expire."
  type        = number
  default     = 365
}

variable "cloudtrail_force_destroy" {
  description = "Let terraform destroy the trail bucket even when it holds log files. Off: audit logs outlive the install unless you ask otherwise."
  type        = bool
  default     = false
}

variable "enable_otel" {
  description = "Create the IAM role (EKS Pod Identity) the OpenTelemetry collector uses to write traces to X-Ray and metrics to CloudWatch (the collector itself is the straiker-otel chart, installed by the installer)."
  type        = bool
  default     = false
}

variable "otel_namespace" {
  description = "Namespace of the OpenTelemetry collector (Pod Identity association)."
  type        = string
  default     = "observability"
}

variable "otel_service_account" {
  description = "ServiceAccount of the OpenTelemetry collector."
  type        = string
  default     = "otel-collector"
}
