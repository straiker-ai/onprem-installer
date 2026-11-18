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

variable "enable_waf" {
  description = "Create the AWS WAF Web ACL for the edge ALB (waf.tf). Set by install-straiker.sh for edgeType=alb/xalb; charts/straiker-edge attaches it through the wafv2-acl-arn Ingress annotation."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes allowed from one source IP before WAF blocks it (rate-based rule). 0 = no rate rule. The default (~33 requests/second sustained) leaves room for an AI app calling the Detect API from one NAT address; lower it for console-only exposure."
  type        = number
  default     = 10000

  validation {
    condition     = var.waf_rate_limit == 0 || (var.waf_rate_limit >= 10 && var.waf_rate_limit <= 2000000000)
    error_message = "waf_rate_limit must be 0 (off) or between 10 and 2000000000."
  }
}

variable "waf_host_allowlists" {
  description = "Per-hostname source CIDRs, e.g. { \"api.acme.com\" = [\"203.0.113.0/24\"] }: a request for that host from any other address is blocked. Hosts not listed are open to every address (subject to the other rules)."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for cidrs in values(var.waf_host_allowlists) : length(cidrs) > 0 && alltrue([for c in cidrs : can(cidrnetmask(c))])])
    error_message = "Each waf_host_allowlists entry needs at least one IPv4 CIDR (a.b.c.d/n)."
  }
}

variable "waf_managed_rule_groups" {
  description = <<-EOT
    AWS managed rule groups on the Web ACL, keyed by rule group name. priority orders them among themselves;
    count_rules are rules of that group switched from BLOCK to COUNT. The request-body rules are counted by default
    because the Detect API receives prompts that are attack strings by design (see waf.tf).
  EOT
  type = map(object({
    priority    = number
    vendor      = optional(string, "AWS")
    count_rules = optional(list(string), [])
  }))
  default = {
    AWSManagedRulesAmazonIpReputationList = { priority = 0 }
    AWSManagedRulesCommonRuleSet = {
      priority = 1
      count_rules = [
        "SizeRestrictions_BODY",
        "CrossSiteScripting_BODY",
        "GenericRFI_BODY",
        "GenericLFI_BODY",
        "EC2MetaDataSSRF_BODY",
        # The console's own cookies (login redirect, session) can match this rule: it blocked a sign-in page load.
        "EC2MetaDataSSRF_COOKIE",
      ]
    }
    AWSManagedRulesKnownBadInputsRuleSet = {
      priority    = 2
      count_rules = ["Log4JRCE_BODY", "JavaDeserializationRCE_BODY"]
    }
  }
}

variable "waf_log_retention_days" {
  description = "Retention of the WAF log group (aws-waf-logs-<cluster>-edge) in days."
  type        = number
  default     = 30
}
