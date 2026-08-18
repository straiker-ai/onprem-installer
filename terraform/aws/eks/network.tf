module "vpc" {
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
