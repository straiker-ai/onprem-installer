# Karpenter IAM + SQS interruption queue — pure AWS resources, no Kubernetes API needed.
# The Helm release and CRDs live in karpenter-install.sh (run after tofu apply).
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  enable_pod_identity             = true
  create_pod_identity_association = true
  namespace                       = "karpenter"

  # Pin stable names so karpenter-install.sh can reference them without guessing.
  node_iam_role_name            = "KarpenterNodeRole-${var.cluster_name}"
  node_iam_role_use_name_prefix = false

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonEKS_CNI_Policy         = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    # Explicit rather than relying on the module's own defaults — nodes need to
    # pull the mirrored images from ECR (terraform/aws/artifacts).
    AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }
}

# Karpenter v1.x manages its own EC2 instance profiles. The terraform-aws-modules/karpenter
# module at ~>20.0 does not include these permissions, so we add them inline.
resource "aws_iam_role_policy" "karpenter_instance_profile" {
  name = "karpenter-instance-profile-mgmt"
  role = module.karpenter.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:ListInstanceProfiles",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile",
      ]
      Resource = "*"
    }]
  })
}
