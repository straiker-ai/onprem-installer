output "self_signed_certificate_arn" {
  value       = var.enable_self_signed_cert ? aws_acm_certificate.self_signed[0].arn : ""
  description = "ARN of the temporary self-signed ACM certificate. Empty when enable_self_signed_cert=false."
}

output "bastion_instance_id" {
  value       = var.enable_bastion ? aws_instance.bastion[0].id : ""
  description = "Instance ID of the temporary verification bastion. Empty when enable_bastion=false."
}
