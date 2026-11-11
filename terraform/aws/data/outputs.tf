output "kms_key_arns" {
  value = { for k, v in aws_kms_key.this : k => v.arn }
}

output "aurora_clusters" {
  description = "Per Aurora cluster (key = aurora_clusters key): writer and reader endpoints, port, and the RDS-managed master secret ARN."
  value = {
    for k, c in aws_rds_cluster.aurora : k => {
      id                = c.cluster_identifier
      endpoint          = c.endpoint
      reader_endpoint   = c.reader_endpoint
      port              = var.aurora.port
      master_secret_arn = c.master_user_secret[0].secret_arn
    }
  }
}

# The "platform" cluster, under the names the installer read before aurora_clusters existed.
output "aurora_endpoint" {
  description = "Platform cluster writer endpoint (null when aurora.enabled = false)."
  value       = try(aws_rds_cluster.aurora["platform"].endpoint, null)
}

output "aurora_reader_endpoint" {
  value = try(aws_rds_cluster.aurora["platform"].reader_endpoint, null)
}

output "aurora_port" {
  value = var.aurora.port
}

output "aurora_master_secret_arn" {
  description = "Secrets Manager secret (RDS-managed) holding the platform cluster's master user/password."
  value       = try(aws_rds_cluster.aurora["platform"].master_user_secret[0].secret_arn, null)
}

output "cache_endpoints" {
  description = "Per cache: endpoint address and port (TLS is always on for ElastiCache Serverless)."
  value = {
    for k, c in aws_elasticache_serverless_cache.this : k => {
      address = c.endpoint[0].address
      port    = c.endpoint[0].port
    }
  }
}

output "redis_replication_groups" {
  description = "Per node-based replication group: primary/reader endpoint, port and the Secrets Manager secret (host, port, auth_token, tls, url)."
  value = {
    for k, g in aws_elasticache_replication_group.this : k => {
      primary_endpoint = g.primary_endpoint_address
      reader_endpoint  = g.reader_endpoint_address
      port             = g.port
      secret_arn       = aws_secretsmanager_secret.redis[k].arn
      secret_name      = aws_secretsmanager_secret.redis[k].name
    }
  }
}

output "opensearch_domains" {
  description = "Per OpenSearch domain: VPC endpoint (HTTPS 443), ARN and the Secrets Manager secret holding the master login."
  value = {
    for k, d in aws_opensearch_domain.this : k => {
      endpoint    = d.endpoint
      arn         = d.arn
      secret_name = aws_secretsmanager_secret.opensearch[k].name
    }
  }
}

output "msk_cluster_arns" {
  value = { for k, c in aws_msk_serverless_cluster.this : k => c.arn }
}

output "efs_file_system_ids" {
  description = "Value for charts/straiker-system efs.fileSystemId."
  value       = { for k, f in aws_efs_file_system.this : k => f.id }
}

output "secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}

output "pod_identity_role_arns" {
  value = { for k, r in aws_iam_role.pod : k => r.arn }
}

output "s3_bucket_names" {
  description = "Bucket key => bucket name."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "dynamodb_table_names" {
  description = "Table key => table name."
  value       = { for k, t in aws_dynamodb_table.this : k => t.name }
}

output "secret_names" {
  description = "Secrets Manager key => secret name."
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.name }
}
