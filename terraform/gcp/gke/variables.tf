variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name, used as a prefix for all resources"
  type        = string
  default     = "s6r-onprem"
}

variable "cluster_version" {
  description = "Kubernetes minor version (release channel still governs the exact patch)"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the primary (node) subnet range"
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range CIDR for Pod IPs (VPC-native cluster)"
  type        = string
  default     = "10.16.0.0/14"
}

variable "services_cidr" {
  description = "Secondary range CIDR for Service IPs (VPC-native cluster)"
  type        = string
  default     = "10.20.0.0/20"
}

variable "system_node_machine_type" {
  description = "Machine type for the always-on system node pool (runs Karpenter's controller + core cluster addons)"
  type        = string
  default     = "e2-standard-4"
}

variable "system_node_count" {
  description = "Fixed node count for the system pool (Karpenter manages all application capacity separately)"
  type        = number
  default     = 2
}
