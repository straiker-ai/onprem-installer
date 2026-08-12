variable "region" {
  description = "AWS region"
  type        = string
}

variable "prefix" {
  description = "Prefix for resource names (ECR repos, S3 bucket, IAM role)"
  type        = string
  default     = "s6r-onprem"
}

variable "cluster_name" {
  description = "EKS cluster name the hauler role's pod identity association binds to. Works the same whether this installer provisioned the cluster or it's a customer's own — pod identity only needs the cluster name, not OIDC provider details."
  type        = string
  default     = "s6r-onprem"
}

variable "namespace" {
  description = "Kubernetes namespace the hauling Job's ServiceAccount runs in"
  type        = string
  default     = "straiker-system"
}

variable "service_account_name" {
  description = "Kubernetes ServiceAccount name the hauling Job runs as"
  type        = string
  default     = "straiker-artifact-hauler"
}

variable "workload_namespace" {
  description = "Namespace of the workload that reads models from S3. Leave empty to create the reader role without binding it yet (straiker-platform's actual namespace isn't known from this chart)."
  type        = string
  default     = ""
}

variable "workload_service_account_name" {
  description = "ServiceAccount name of the workload that reads models from S3. Leave empty to skip the pod identity binding."
  type        = string
  default     = ""
}
