# Resolved by looking up the cluster itself rather than taking vpc_id/
# private_subnet_ids as variables -- works identically whether this
# installer or the customer provisioned the cluster, and doesn't depend on
# terraform/aws/eks's vpc_id/private_subnet_ids outputs ever having been
# captured into install-straiker.sh's metadata (they currently aren't).
# Matches this repo's existing "discover subnets by tag, not by ID" idiom
# (see terraform/aws/eks/network.tf's karpenter.sh/discovery tagging).
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.this.vpc_config[0].vpc_id]
  }
  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
