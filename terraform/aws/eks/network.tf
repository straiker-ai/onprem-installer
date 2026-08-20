module "vpc" {
  count = local.create_vpc ? 1 : 0

  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = local.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  # karpenter.sh/discovery per-AZ rather than in private_subnet_tags above
  # (which would apply it uniformly to every AZ regardless of
  # provision_strategy) -- only local.karpenter_azs' subnet(s) get it, so
  # Karpenter's EC2NodeClasses (which discover subnets by this tag, not an
  # explicit ID list) never see the other AZs' subnets under "min".
  private_subnet_tags_per_az = {
    for az in local.karpenter_azs : az => {
      "karpenter.sh/discovery" = var.cluster_name
    }
  }

  tags = local.common_tags
}

# ── Bring-your-own-VPC (vpc_id set): AZ lookup + tagging ──────────────────
# module.vpc (above) applies public_subnet_tags/private_subnet_tags/
# private_subnet_tags_per_az itself when it creates the VPC. In BYO mode
# nothing creates those subnets, so this block replicates the same tags onto
# the customer-supplied ones directly -- Karpenter's EC2NodeClasses
# (charts/straiker-system/templates/karpenter-*.yaml) discover subnets
# exclusively via the karpenter.sh/discovery tag, not by ID, so this can't be
# skipped. Deliberately tags only subnets, never the VPC resource itself --
# scripts/nuke-eks.sh's safety gate depends on a BYO VPC never acquiring
# Straiker's own vendor/managed_by tags.
data "aws_subnet" "private" {
  count = local.create_vpc ? 0 : length(var.private_subnet_ids)
  id    = var.private_subnet_ids[count.index]
}

resource "aws_ec2_tag" "public_elb" {
  count       = local.create_vpc ? 0 : length(var.public_subnet_ids)
  resource_id = var.public_subnet_ids[count.index]
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_internal_elb" {
  count       = local.create_vpc ? 0 : length(var.private_subnet_ids)
  resource_id = var.private_subnet_ids[count.index]
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

# Only local.karpenter_azs' subnet(s) get tagged, mirroring module.vpc's own
# private_subnet_tags_per_az -- respects provision_strategy=min's AZ
# confinement (see locals.tf) instead of tagging every BYO private subnet.
resource "aws_ec2_tag" "karpenter_discovery" {
  for_each = local.create_vpc ? {} : {
    for idx, sid in var.private_subnet_ids : sid => sid
    if contains(local.karpenter_azs, data.aws_subnet.private[idx].availability_zone)
  }

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}
