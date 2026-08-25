variable "region" {
  description = "AWS region"
  type        = string
}

variable "prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "s6r-onprem"
}

variable "cluster_name" {
  description = "EKS cluster name — used to look up the cluster's own VPC/private subnets (kubernetes.io/role/internal-elb tag) via data sources instead of taking them as separate variables. Works the same whether this installer or the customer provisioned the cluster."
  type        = string
}

variable "enable_self_signed_cert" {
  description = "Generate a temporary self-signed certificate and import it into ACM, for edgeType=alb installs that don't have a real certificate yet. The customer/SE swaps in a real one later via 'aws acm import-certificate --certificate-arn <same-arn>' (see cert.tf's ignore_changes lifecycle rule) — no re-apply needed."
  type        = bool
  default     = false
}

variable "san_hostnames" {
  description = "Hostnames the self-signed certificate should cover (e.g. app.<domain>, defend.<domain>, ascend.<domain>). Computed in bash (install-straiker.sh's custom_origin_hostname()) rather than rebuilt here, so hostname logic lives in exactly one place. Only used when enable_self_signed_cert=true."
  type        = list(string)
  default     = []
}

variable "enable_bastion" {
  description = "Provision a tiny EC2 bastion (no public IP, no SSH key — accessed via 'aws ssm start-session' port-forwarding) so whoever is installing can verify the internal ALB is reachable before handoff. Not a customer-facing access path."
  type        = bool
  default     = false
}
