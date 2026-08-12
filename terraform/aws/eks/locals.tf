locals {
  azs             = var.availability_zones
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]

  common_tags = {
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
  }
}

