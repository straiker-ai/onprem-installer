output "bastion_instance_id" {
  value       = var.enable_bastion ? aws_instance.bastion[0].id : ""
  description = "Instance ID of the temporary verification bastion. Empty when enable_bastion=false."
}

output "alb_controller_role_arn" {
  value       = var.enable_alb_controller ? aws_iam_role.alb_controller[0].arn : ""
  description = "ARN of the AWS Load Balancer Controller's IAM role. Empty when enable_alb_controller=false (edgeType=tailscale installs)."
}

output "dns_validated_certificate_arn" {
  value       = var.enable_route53_automation ? aws_acm_certificate_validation.dns_validated[0].certificate_arn : ""
  description = "ARN of the real, DNS-validated ACM certificate. Empty when enable_route53_automation=false."
}

output "external_dns_role_arn" {
  value       = var.enable_external_dns ? aws_iam_role.external_dns[0].arn : ""
  description = "ARN of ExternalDNS's IAM role. Empty when enable_external_dns=false."
}

output "cert_manager_role_arn" {
  value       = var.enable_cert_manager_route53 ? aws_iam_role.cert_manager[0].arn : ""
  description = "ARN of cert-manager's IAM role for the Route53 DNS-01 solver. Empty when enable_cert_manager_route53=false."
}

output "route53_hosted_zone_id" {
  value       = var.enable_cert_manager_route53 ? data.aws_route53_zone.cert_manager[0].zone_id : ""
  description = "Route53 public hosted zone ID for var.domain -- feeds charts/straiker-edge's tailscale.hostedZoneId. Empty when enable_cert_manager_route53=false."
}
