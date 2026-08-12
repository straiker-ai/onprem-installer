variable "cluster_name" {
  description = "EKS cluster name, used as a prefix for all resources"
  type        = string
  default     = "s6r-onprem"
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to deploy subnets into (2 recommended for cost, 3 for maximum resilience)"
  type        = list(string)
}

variable "system_node_instance_types" {
  description = "Instance types for the system managed node group (runs Karpenter + addons)"
  type        = list(string)
  default     = ["m5.large", "m5a.large"]
}
