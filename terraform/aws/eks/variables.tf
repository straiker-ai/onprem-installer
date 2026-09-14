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
  validation {
    # Catches a leading/trailing/doubled comma from a CSV source (e.g. a
    # shell script building this list) turning into a "" element -- caught a
    # real install where that empty ID reached an aws_ec2_tag resource and
    # failed with a cryptic "InvalidID: The ID '' is not valid" instead of
    # a clear message here.
    condition     = var.private_subnet_ids == null || alltrue([for id in var.private_subnet_ids : id != ""])
    error_message = "private_subnet_ids must not contain empty entries (check for a leading/trailing/doubled comma)."
  }
}

variable "public_subnet_ids" {
  description = "Required when vpc_id is set. Tagged kubernetes.io/role/elb for the AWS Load Balancer Controller."
  type        = list(string)
  default     = null
  validation {
    condition     = var.public_subnet_ids == null || alltrue([for id in var.public_subnet_ids : id != ""])
    error_message = "public_subnet_ids must not contain empty entries (check for a leading/trailing/doubled comma)."
  }
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

variable "single_nat_gateway" {
  description = <<-EOT
    Overrides how many NAT gateways (and therefore how many Elastic IPs) the
    created VPC gets, independently of provision_strategy. null (default)
    keeps the historical coupling: one NAT under provision_strategy=min, one
    per registered AZ under ha/max.

    Set true to run multi-AZ nodes (ha/max) behind a SINGLE NAT gateway. The
    reason to want this is usually egress-IP allow-listing, not cost: one NAT
    means one stable source address for a downstream firewall/vendor allowlist
    to pin, where ha/max otherwise present 3 different egress IPs that all
    have to be listed and re-listed whenever a NAT is replaced.

    Trade-offs: the single NAT becomes an AZ-level single point of failure for
    outbound traffic (nodes in the other AZs keep running, but lose egress if
    that AZ goes away), and their egress crosses AZ boundaries, which incurs
    inter-AZ data transfer charges. Ignored entirely in bring-your-own-VPC
    mode -- this module creates no NAT gateway there at all.
  EOT
  type        = bool
  default     = null
}

variable "cluster_endpoint_public_access" {
  description = <<-EOT
    Whether the Kubernetes API server is reachable from the internet. true
    (default) preserves this installer's historical behaviour.

    Set false for a private-only endpoint. AWS then resolves the cluster
    endpoint through PUBLIC DNS to its PRIVATE VPC address, so kubectl works
    from anywhere with routed connectivity to the VPC (Transit Gateway, Direct
    Connect, VPN) with no bastion, no Route 53 Resolver inbound endpoint and
    no CloudShell VPC environment. It does NOT work from a host that can only
    reach the VPC over the public internet.

    Two things must hold before flipping this, or you lock yourself out:
      - cluster_endpoint_private_access_cidrs below must cover whatever
        network your operators (and any CI running helm) actually come from.
      - The nodes keep working either way; private access is already enabled
        unconditionally by the upstream module's own default.
  EOT
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the PUBLIC API endpoint. Defaults to
    0.0.0.0/0 (AWS's own default). Narrowing this to a corporate egress range
    is the lighter-touch alternative to disabling public access outright --
    it needs no VPC routing at all, so it is often the right first step for a
    customer who wants the endpoint off the open internet but is not ready to
    depend on Transit Gateway/Direct Connect reachability. Ignored when
    cluster_endpoint_public_access is false.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_endpoint_private_access_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the PRIVATE API endpoint on 443, added to
    the EKS-managed cluster security group. Empty (default) leaves that group
    as the upstream module builds it, which admits the node security group and
    nothing else -- fine while public access is on, but it means a
    connected-network operator cannot reach a private-only endpoint.

    Set this to the on-prem/corporate ranges that reach the VPC over Transit
    Gateway, Direct Connect or VPN whenever cluster_endpoint_public_access is
    false. AWS documents this cluster-security-group rule as a requirement for
    the "connected network" access pattern.
  EOT
  type        = list(string)
  default     = []
}
