locals {
  create_vpc = var.vpc_id == null

  # In BYO mode (create_vpc = false), AZs come from the supplied subnets
  # (see data.aws_subnet.private in network.tf) instead of this variable --
  # Terraform's conditional operator short-circuits, so var.availability_zones
  # being null in that mode is never actually evaluated here.
  azs             = local.create_vpc ? var.availability_zones : data.aws_subnet.private[*].availability_zone
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]

  # Resolved VPC/subnet IDs -- either what module.vpc created, or what the
  # customer supplied via vpc_id/private_subnet_ids/public_subnet_ids.
  vpc_id             = local.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  private_subnet_ids = local.create_vpc ? module.vpc[0].private_subnets : var.private_subnet_ids
  public_subnet_ids  = local.create_vpc ? module.vpc[0].public_subnets : var.public_subnet_ids

  common_tags = {
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
  }

  # provision_strategy's concrete effects, computed once here rather than
  # inlined at each use site (network.tf's NAT/discovery-tag subnets, eks.tf's
  # system node group).
  single_nat_gateway = var.provision_strategy == "min"

  # Karpenter's EC2NodeClasses (charts/straiker-system) discover subnets by
  # the karpenter.sh/discovery tag (applied per-AZ via the vpc module's
  # private_subnet_tags_per_az, see network.tf), not by an explicit subnet
  # list -- so confining Karpenter-launched application nodes to one AZ
  # under "min" is just a matter of which AZs get that tag, with no change
  # needed on the chart side. karpenter_azs is that AZ list.
  karpenter_azs = var.provision_strategy == "min" ? [local.azs[0]] : local.azs

  # local.private_subnet_ids is real subnet IDs (module.vpc's output, or the
  # customer-supplied ones in BYO mode), not the CIDR list above -- needed
  # directly (not via a tag) since eks_managed_node_groups takes real
  # subnet_ids.
  system_node_subnet_ids = var.provision_strategy == "min" ? [local.private_subnet_ids[0]] : local.private_subnet_ids

  system_node_sizing = {
    min = { min_size = 1, max_size = 1, desired_size = 1 }
    ha  = { min_size = 2, max_size = 3, desired_size = 2 }
    max = { min_size = 3, max_size = 5, desired_size = 3 }
  }[var.provision_strategy]
}

