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
  description = "CIDR block for the VPC. Ignored when vpc_id is set (bring-your-own-VPC)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to register subnets in. EKS's control plane requires >=2 regardless of provision_strategy (AWS rejects CreateCluster with fewer) -- this is what actually gets subnets/registered with the cluster; provision_strategy separately controls how much of it real workloads/NAT actually use. Required unless vpc_id is set, in which case AZs are instead derived from the supplied subnet IDs."
  type        = list(string)
  default     = null
  validation {
    condition     = var.vpc_id != null || var.availability_zones != null
    error_message = "availability_zones is required unless vpc_id (bring-your-own-VPC) is set."
  }
}

variable "vpc_id" {
  description = <<-EOT
    Bring-your-own VPC: set to use an existing VPC instead of creating one
    (e.g. when an SCP denies ec2:CreateVpc). Requires private_subnet_ids and
    public_subnet_ids together. Leave null (default) to create a VPC as today.

    IAM needed instead of ec2:CreateVpc/CreateSubnet/CreateNatGateway/...:
      ec2:DescribeVpcs, ec2:DescribeSubnets, ec2:DescribeRouteTables,
      ec2:CreateTags, ec2:DeleteTags (to tag the supplied subnets
      kubernetes.io/role/*-elb and karpenter.sh/discovery -- Karpenter's
      EC2NodeClasses discover subnets by that tag, not by ID, and this
      cannot be changed chart-side without much larger surgery).

    This module does NOT create a NAT gateway in this mode -- the supplied
    private subnets must already have outbound internet routing.
  EOT
  type        = string
  default     = null
  validation {
    condition     = var.vpc_id == null || (var.private_subnet_ids != null && var.public_subnet_ids != null && var.byo_vpc_confirm)
    error_message = "When vpc_id is set, private_subnet_ids, public_subnet_ids, and byo_vpc_confirm=true are all required."
  }
  validation {
    condition     = var.vpc_id == null || length(coalesce(var.private_subnet_ids, [])) >= 2
    error_message = "private_subnet_ids must contain at least 2 subnets (EKS control-plane minimum)."
  }
}

variable "private_subnet_ids" {
  description = "Required when vpc_id is set. Order matters under provision_strategy=min: only the first subnet's AZ is used for the system node group and Karpenter-launched nodes."
  type        = list(string)
  default     = null
}

variable "public_subnet_ids" {
  description = "Required when vpc_id is set. Tagged kubernetes.io/role/elb for the AWS Load Balancer Controller."
  type        = list(string)
  default     = null
}

variable "byo_vpc_confirm" {
  description = "Must be true when vpc_id is set. Deliberate speed bump, since BYO mode changes nuke-eks.sh's blast radius (it must never delete a customer-owned VPC)."
  type        = bool
  default     = false
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
