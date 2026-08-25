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

variable "san_hostnames" {
  description = "Hostnames the DNS-validated certificate should cover (e.g. straiker.<domain>, straiker-defend.<domain>, straiker-ascend.<domain>). Computed in bash (install-straiker.sh's custom_domain_hostname()) rather than rebuilt here, so hostname logic lives in exactly one place. Only used when enable_route53_automation=true (see route53.tf) — alb and xalb-without-route53-automation both require an explicit --alb-certificate-arn instead."
  type        = list(string)
  default     = []
}

variable "enable_bastion" {
  description = "Provision a tiny EC2 bastion (no public IP, no SSH key — accessed via 'aws ssm start-session' port-forwarding) so whoever is installing can verify the internal ALB is reachable before handoff. Not a customer-facing access path."
  type        = bool
  default     = false
}

variable "alb_controller_namespace" {
  description = "Namespace the AWS Load Balancer Controller runs in. Its IAM role/Pod Identity association is created unconditionally by this module (this module only ever runs when edgeType: alb or xalb, so the controller is always needed regardless of the bastion/Route53 choices above/below)."
  type        = string
  default     = "kube-system"
}

variable "alb_controller_service_account_name" {
  description = "Kubernetes ServiceAccount name for the AWS Load Balancer Controller (Pod Identity binding)."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "enable_route53_automation" {
  description = "Opt-in via --xalb-route53, off by default, for edgeType=xalb only (always false for alb, which always requires an explicit --alb-certificate-arn — no self-signed fallback for either edge type). When true: looks up the existing Route53 zone for var.domain, auto-requests+validates a real ACM certificate via DNS validation (route53.tf), and creates the ExternalDNS IAM role/Pod Identity association (external_dns.tf) so the app hostnames stay pointed at the ALB automatically. Only works when that zone is in this same AWS account. The default (false) requires an explicit --alb-certificate-arn and manual DNS management instead — the option that works regardless of account/DNS-provider topology. Certificate and DNS record are gated together since both need the same Route53 zone access."
  type        = bool
  default     = false
}

variable "domain" {
  description = "Bare base domain (e.g. \"acmecorp.com\", not \"straiker.acmecorp.com\") to look up the Route53 zone for. Only used when enable_route53_automation=true."
  type        = string
  default     = ""
}

variable "external_dns_namespace" {
  description = "Namespace ExternalDNS runs in. Only relevant when enable_route53_automation=true."
  type        = string
  default     = "kube-system"
}

variable "external_dns_service_account_name" {
  description = "Kubernetes ServiceAccount name for ExternalDNS (Pod Identity binding). Only relevant when enable_route53_automation=true."
  type        = string
  default     = "external-dns"
}
