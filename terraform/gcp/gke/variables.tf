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
  description = "Nodes per zone in the system pool (Karpenter manages all application capacity separately). Total nodes = this * the number of zones provision_strategy selects (1/2/3 for min/ha/max) -- a regional GKE node pool's node_count is per-zone, not total."
  type        = number
  default     = 1
}

variable "provision_strategy" {
  description = <<-EOT
    min (default): cheapest/smallest footprint (PoC only) -- zonal cluster
      (single control-plane replica, cheaper than GKE's regional/HA control
      plane) with the system node pool confined to that one zone. Accepts
      that a zone outage takes the whole service down.
      Known gap: Karpenter-launched application nodes (charts/straiker-
      system's GCENodeClass) aren't yet zone-restricted to match -- GCP
      subnets are regional, not zonal like AWS, so there's no
      subnet-tag-discovery equivalent to lean on here; that needs a
      follow-up change to the GCENodeClass template's own zone field.
    ha: regional cluster -- system node pool spread across 2 zones in the
      region.
    max: same as ha but spread across 3 zones for maximum resilience.
  EOT
  type        = string
  default     = "min"
  validation {
    condition     = contains(["min", "ha", "max"], var.provision_strategy)
    error_message = "provision_strategy must be one of: min, ha, max"
  }
}
