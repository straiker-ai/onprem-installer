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
  description = "List of AZs to register subnets in. EKS's control plane requires >=2 regardless of provision_strategy (AWS rejects CreateCluster with fewer) -- this is what actually gets subnets/registered with the cluster; provision_strategy separately controls how much of it real workloads/NAT actually use."
  type        = list(string)
}

variable "system_node_instance_types" {
  description = "Instance types for the system managed node group (runs Karpenter + addons)"
  type        = list(string)
  default     = ["m5.large", "m5a.large"]
}

variable "provision_strategy" {
  description = <<-EOT
    min (default): cheapest/smallest footprint (PoC only) -- single NAT
      gateway, system node group and Karpenter-launched nodes confined to
      the first AZ in availability_zones. Accepts that an outage of that
      one AZ takes the whole service down; the EKS control plane itself
      still spans every registered AZ regardless (AWS-managed, not ours to
      shrink).
    ha: multi-AZ -- one NAT gateway per registered AZ, system node group
      spread across all of them.
    max: same as ha plus extra system-node headroom for maximum resilience.
  EOT
  type        = string
  default     = "min"
  validation {
    condition     = contains(["min", "ha", "max"], var.provision_strategy)
    error_message = "provision_strategy must be one of: min, ha, max"
  }
}
