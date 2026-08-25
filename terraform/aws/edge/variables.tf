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

variable "enable_alb_controller" {
  description = "Create the AWS Load Balancer Controller's IAM role/Pod Identity association. Default true (matches this module's original alb/xalb-only behavior) -- set false for a tailscale-only install (this module also runs for edgeType=tailscale now, for cert_manager.tf's Route53 IAM role, which has no use for an ALB controller)."
  type        = bool
  default     = true
}

variable "alb_controller_namespace" {
  description = "Namespace the AWS Load Balancer Controller runs in. Only relevant when enable_alb_controller=true."
  type        = string
  default     = "kube-system"
}

variable "alb_controller_service_account_name" {
  description = "Kubernetes ServiceAccount name for the AWS Load Balancer Controller (Pod Identity binding)."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "enable_route53_automation" {
  description = "Opt-in via --alb-route53 (edgeType=alb) or --xalb-route53 (edgeType=xalb), off by default. When true: looks up the existing Route53 zone for var.domain and auto-requests+validates a real ACM certificate via DNS validation (route53.tf). Only works when that zone is in this same AWS account. The default (false) requires an explicit --alb-certificate-arn instead — the option that works regardless of account/DNS-provider topology. See enable_external_dns for the separate (xalb-only) DNS-record-sync toggle."
  type        = bool
  default     = false
}

variable "enable_external_dns" {
  description = "Opt-in via --xalb-route53, off by default, for edgeType=xalb only (never alb -- alb is internal-only, so there's no public DNS record for ExternalDNS to manage). When true: creates the ExternalDNS IAM role/Pod Identity association (external_dns.tf) so the app hostnames stay pointed at the ALB automatically. Kept as its own variable rather than reusing enable_route53_automation because alb now also sets that flag (for its own certificate, via --alb-route53) without wanting ExternalDNS installed."
  type        = bool
  default     = false
}

variable "domain" {
  description = "Bare base domain (e.g. \"acmecorp.com\", not \"straiker.acmecorp.com\") to look up the Route53 zone for. Used when enable_route53_automation=true (route53.tf's ACM certificate) and/or enable_cert_manager_route53=true (cert_manager.tf's cert-manager IAM role) -- same zone lookup, same underlying concept (\"the customer's own domain\"), reused across both rather than a separate variable per feature."
  type        = string
  default     = ""
}

variable "external_dns_namespace" {
  description = "Namespace ExternalDNS runs in. Only relevant when enable_external_dns=true."
  type        = string
  default     = "kube-system"
}

variable "external_dns_service_account_name" {
  description = "Kubernetes ServiceAccount name for ExternalDNS (Pod Identity binding). Only relevant when enable_external_dns=true."
  type        = string
  default     = "external-dns"
}

variable "enable_cert_manager_route53" {
  description = "For edgeType=tailscale only. When true: looks up the existing Route53 zone for var.domain and creates cert-manager's IAM role/Pod Identity association (cert_manager.tf) so its Route53 DNS-01 solver can issue a real Let's Encrypt certificate for the customer's domain. Only works when that zone is in this same AWS account (same requirement as enable_route53_automation)."
  type        = bool
  default     = false
}

variable "cert_manager_namespace" {
  description = "Namespace cert-manager runs in. Only relevant when enable_cert_manager_route53=true. Default matches jetstack/cert-manager's own Helm chart default."
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_service_account_name" {
  description = "Kubernetes ServiceAccount name for cert-manager (Pod Identity binding). Only relevant when enable_cert_manager_route53=true. Default matches jetstack/cert-manager's own Helm chart default."
  type        = string
  default     = "cert-manager"
}
