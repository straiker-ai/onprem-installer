module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  # Both variables default to today's behaviour (public endpoint, open to
  # 0.0.0.0/0). See their descriptions in variables.tf before flipping either:
  # a private-only endpoint depends on the operator's network actually routing
  # to this VPC, and on cluster_endpoint_private_access_cidrs below.
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Reaching a private-only endpoint from a connected network (Transit
  # Gateway/Direct Connect/VPN) needs an explicit 443 ingress rule on the
  # EKS-managed cluster security group -- the module's own default admits the
  # node security group and nothing else. Empty list = no rule, preserving the
  # previous behaviour exactly.
  cluster_security_group_additional_rules = length(var.cluster_endpoint_private_access_cidrs) > 0 ? {
    connected_network_https = {
      description = "Kubernetes API from connected networks (TGW/DX/VPN)"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = var.cluster_endpoint_private_access_cidrs
    }
  } : {}

  enable_cluster_creator_admin_permissions = true
  bootstrap_self_managed_addons            = false

  cluster_addons = {
    vpc-cni = {
      most_recent              = true
      before_compute           = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      # Default WARM_ENI_TARGET=1 keeps a whole spare network interface of idle IPs on every node. With one
      # private /24 per AZ (251 IPs) and large nodes (GPU, ClickHouse) that exhausts the subnet and new pods
      # fail with "failed to assign an IP address to container". Keep only a few spare IPs per node instead.
      configuration_values = jsonencode({
        env = {
          WARM_IP_TARGET    = tostring(local.cni_warm_ip_target)
          MINIMUM_IP_TARGET = tostring(local.cni_minimum_ip_target)
        }
      })
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    # The model weights cache and the shared models volume are EFS: without this driver the volume binds (a static PV) but no pod can
    # mount it. The data layer creates the file system and mount targets; this is the CSI side. The controller tolerates the system
    # node's taint; the node DaemonSet already tolerates everything (GPU nodes included).
    aws-efs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.efs_csi_irsa.iam_role_arn
      configuration_values = jsonencode({
        controller = { tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }] }
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    # The metrics API (kubectl top, and every HPA: without it an HPA never changes a replica count). It runs on the
    # tainted system node, so it tolerates CriticalAddonsOnly like the other add-ons.
    metrics-server = {
      most_recent = true
      configuration_values = jsonencode({
        tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
      })
    }
  }

  # Minimal node group exclusively for system workloads (Karpenter + addons).
  # Karpenter manages all application nodes from here.
  eks_managed_node_groups = {
    system = {
      instance_types = var.system_node_instance_types
      ami_type       = var.system_node_ami_type
      subnet_ids     = local.system_node_subnet_ids
      min_size       = local.system_node_sizing.min_size
      max_size       = local.system_node_sizing.max_size
      desired_size   = local.system_node_sizing.desired_size

      # Customer-managed key on the root volume (encrypt_node_volumes). Without it the module's default volume is used, unchanged.
      block_device_mappings = var.encrypt_node_volumes ? {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_volume_size_gb
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = aws_kms_key.ebs[0].arn
            delete_on_termination = true
          }
        }
      } : {}

      labels = {
        "node.kubernetes.io/purpose" = "system"
      }

      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  # The EKS metrics-server add-on serves on 10251 (not 10250/443), which the module's recommended node rules do not open: without
  # this the API server cannot reach it and the metrics API stays "FailedDiscoveryCheck" (HPAs show <unknown>).
  node_security_group_additional_rules = {
    ingress_cluster_metrics_server = {
      description                   = "Cluster API to metrics-server"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# IRSA for VPC CNI — aws-node pods get EC2 credentials via projected OIDC token,
# not the node role. This avoids the chicken-and-egg with eks-pod-identity-agent:
# IRSA tokens are filesystem-projected and work before network/CNI is ready.
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

# IRSA for the EBS CSI driver (required to provision PersistentVolumes)
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true
  ebs_csi_kms_cmk_ids   = local.ebs_cmk ? [aws_kms_key.ebs[0].arn] : []

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# IRSA for the EFS CSI driver (mounting the models file system)
module "efs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa", "kube-system:efs-csi-node-sa"]
    }
  }
}

# Customer-managed EBS key: PersistentVolumes (kms_layout = "split") and/or node root volumes (encrypt_node_volumes). The EBS CSI
# role gets kms:CreateGrant/GenerateDataKey on it above. IAM delegation (account root) lets IAM policies use it; with encrypted node
# volumes the Auto Scaling service-linked role also needs the key itself, because the node group's ASG launches the instances.
data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  asg_slr_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

data "aws_iam_policy_document" "ebs_key" {
  count = local.ebs_cmk ? 1 : 0

  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = var.encrypt_node_volumes ? [1] : []
    content {
      sid       = "AutoScalingUsesTheKey"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [local.asg_slr_arn]
      }
    }
  }

  dynamic "statement" {
    for_each = var.encrypt_node_volumes ? [1] : []
    content {
      sid       = "AutoScalingAttachesEncryptedVolumes"
      actions   = ["kms:CreateGrant"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [local.asg_slr_arn]
      }
      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }
}

resource "aws_kms_key" "ebs" {
  count = local.ebs_cmk ? 1 : 0

  description             = "${var.cluster_name} ebs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.ebs_key[0].json
}

resource "aws_kms_alias" "ebs" {
  count = local.ebs_cmk ? 1 : 0

  name          = "alias/${var.cluster_name}-ebs"
  target_key_id = aws_kms_key.ebs[0].key_id
}
