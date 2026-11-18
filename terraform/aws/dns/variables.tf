variable "region" {
  description = "AWS region (the ACM certificate is created here: a load balancer can only use a certificate of its own region)."
  type        = string
}

variable "cluster_name" {
  description = "Install name. Tags the certificate straiker:cluster=<name>, which is how the installer's gateway-cert phase finds and reuses it."
  type        = string
}

variable "domain" {
  description = "Bare base domain, e.g. \"onprem.straiker.ai\": the name of the public Route53 zone (created here when create_zone=true, otherwise it must already exist in this account)."
  type        = string
}

variable "create_zone" {
  description = "Create the public hosted zone for var.domain. Its NS record in the parent zone is still a manual step (the parent is another account, Cloudflare or a registrar); the installer waits for it before going on. false = look an existing zone up by name."
  type        = bool
  default     = false
}

variable "gateway_domain" {
  description = "Host name of the API gateway, e.g. \"api.onprem.straiker.ai\". When set, an ACM certificate for it is requested and its DNS validation record written into the zone. The certificate is not waited for here: it turns ISSUED once the zone is delegated, and the installer's gateway step waits for that. Empty = no certificate."
  type        = string
  default     = ""
}
