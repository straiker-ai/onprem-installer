output "zone_id" {
  description = "Hosted zone id of var.domain (empty when no zone is used)."
  value       = local.zone_id
}

output "name_servers" {
  description = "The four name servers of the created zone: the values of the NS record to add in the parent zone. Empty when create_zone=false."
  value       = var.create_zone ? aws_route53_zone.this[0].name_servers : []
}

output "gateway_certificate_arn" {
  description = "ARN of the gateway certificate (PENDING_VALIDATION until the zone is delegated). Empty when gateway_domain is unset."
  value       = var.gateway_domain != "" ? aws_acm_certificate.gateway[0].arn : ""
}
