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

output "cognito_pools" {
  description = "Per Cognito pool: id, OIDC issuer, app client id, hosted-UI domain and the Secrets Manager secrets (client secret; first-admin password)."
  value = {
    for k, p in aws_cognito_user_pool.this : k => {
      pool_id           = p.id
      issuer            = "https://cognito-idp.${var.region}.amazonaws.com/${p.id}"
      client_id         = aws_cognito_user_pool_client.frontend[k].id
      domain            = "https://${aws_cognito_user_pool_domain.this[k].domain}.auth.${var.region}.amazoncognito.com"
      saml_acs_url      = "https://${aws_cognito_user_pool_domain.this[k].domain}.auth.${var.region}.amazoncognito.com/saml2/idpresponse"
      entity_id         = "urn:amazon:cognito:sp:${p.id}"
      oidc_redirect_uri = "https://${aws_cognito_user_pool_domain.this[k].domain}.auth.${var.region}.amazoncognito.com/oauth2/idpresponse"
      secret_name       = aws_secretsmanager_secret.cognito[k].name
      admin_secret_name = aws_secretsmanager_secret.cognito_admin[k].name
    }
  }
}

output "sso_providers" {
  description = "The customer's identity provider federated into the main pool: name => type (SAML, OIDC, Google, Facebook, LoginWithAmazon, SignInWithApple)."
  value       = { for k in local.sso_names : k => nonsensitive(local.sso[k].type) }
  depends_on  = [aws_cognito_identity_provider.sso]
}

output "ses_domains" {
  description = "Per SES domain: identity ARN, sender address, configuration set, the name servers of a created zone (delegate them from the parent zone) and the DNS records SES needs."
  value = {
    for k, d in var.ses_domains : k => {
      domain            = d.domain
      identity_arn      = aws_sesv2_email_identity.this[k].arn
      sender            = "${d.sender_local_part}@${d.domain}"
      configuration_set = aws_sesv2_configuration_set.this[k].configuration_set_name
      name_servers      = try(aws_route53_zone.ses[k].name_servers, [])
      dns_records = concat(
        [for t in aws_sesv2_email_identity.this[k].dkim_signing_attributes[0].tokens : {
          name = "${t}._domainkey.${d.domain}", type = "CNAME", value = "${t}.dkim.amazonses.com"
        }],
        [
          { name = "${d.mail_from_subdomain}.${d.domain}", type = "MX", value = "10 feedback-smtp.${var.region}.amazonses.com" },
          { name = "${d.mail_from_subdomain}.${d.domain}", type = "TXT", value = "v=spf1 include:amazonses.com ~all" },
          { name = "_dmarc.${d.domain}", type = "TXT", value = "v=DMARC1; p=none;" },
        ],
      )
    }
  }
}

output "ses_existing" {
  description = "The customer's own SES identity in use (null when the installer created one: see ses_domains)."
  value = var.ses_existing == null ? null : {
    identity_arn      = var.ses_existing.identity_arn
    sender            = var.ses_existing.from_address
    configuration_set = var.ses_existing.configuration_set
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

output "saas_frontend" {
  description = "SaaS frontend backends (null when var.saas_frontend is null): DYNAMODB_TABLE_NAME, DYNAMODB_GUARDRAILS_TABLE_NAME, AUDIT_LOGS_STREAM."
  value = local.saas_frontend ? {
    dynamodb_table_name            = aws_dynamodb_table.saas_environment[0].name
    dynamodb_guardrails_table_name = aws_dynamodb_table.saas_guardrail[0].name
    audit_logs_stream              = aws_kinesis_stream.saas_audit[0].name
  } : null
}
