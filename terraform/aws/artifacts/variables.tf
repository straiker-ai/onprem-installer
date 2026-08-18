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
  default     = "straiker"
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

variable "workload_service_account_names" {
  description = "ServiceAccount names (in workload_namespace) that read models from S3 — one binding per name, all to the same reader role (e.g. straiker-inference's shared SA, straiker-defend's SA). Leave empty to skip pod identity bindings entirely."
  type        = list(string)
  default     = []
}

variable "bedrock_mode" {
  description = "When true, create a dedicated IAM role for Bedrock access and bind it to bifrost's ServiceAccount via Pod Identity. Set only when AI_PROVIDER_MODE=bedrock."
  type        = bool
  default     = false
}

variable "bifrost_service_account_name" {
  description = "Kubernetes ServiceAccount name for the bifrost pod (used for Bedrock Pod Identity binding). Only relevant when bedrock_mode=true."
  type        = string
  default     = "straiker-bifrost"
}
