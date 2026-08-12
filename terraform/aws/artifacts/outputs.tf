output "models_bucket_name" {
  value = aws_s3_bucket.models.bucket
}

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.mirror : name => repo.repository_url }
}

output "hauler_role_arn" {
  value = aws_iam_role.hauler.arn
}

output "workload_role_arn" {
  value = aws_iam_role.workload.arn
}
