data "aws_caller_identity" "current" {}

data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_ids)
  id       = each.value
}

locals {
  name = var.cluster_name

  common_tags = merge({
    vendor      = "Straiker"
    build       = "onprem"
    project     = var.cluster_name
    managed_by  = "terraform"
    environment = "onprem"
    Module      = "data"
  }, var.tags)

  # One private subnet per AZ (MSK and EFS need distinct AZs, one mount target per AZ).
  azs = distinct([for s in data.aws_subnet.private : s.availability_zone])
  subnet_by_az = {
    for az in local.azs :
    az => [for s in data.aws_subnet.private : s.id if s.availability_zone == az][0]
  }
  subnet_cidrs = distinct([for s in data.aws_subnet.private : s.cidr_block])

  # Every data service admits the private subnets' CIDRs (pods on Karpenter nodes)
  # and any extra client security groups.
  client_cidrs = local.subnet_cidrs
  client_sgs   = toset(var.client_security_group_ids)

  # Keys: the caller's kms_keys plus the layout keys. transcripts/logs always exist (the new buckets use them); models/secrets
  # only in the "split" layout (fresh installs).
  kms_keys = merge(
    { for k in concat(["transcripts", "logs"], var.kms_layout == "split" ? ["models", "secrets"] : []) : k => {
      description             = null
      deletion_window_in_days = 30
      enable_key_rotation     = true
      tags                    = {}
    } },
    var.kms_keys,
  )

  kms_key_arn         = aws_kms_key.this[var.data_kms_key].arn
  efs_kms_key_arn     = aws_kms_key.this[var.kms_layout == "split" ? "models" : var.data_kms_key].arn
  secrets_kms_key_arn = aws_kms_key.this[var.kms_layout == "split" ? "secrets" : var.data_kms_key].arn

  ha = var.provision_strategy != "min"
}
