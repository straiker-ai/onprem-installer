variable "cluster_name" {
  description = "EKS cluster name; prefix of every resource here (same value as terraform/aws/eks)."
  type        = string
  default     = "s6r-onprem"
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the EKS cluster (output vpc_id of terraform/aws/eks)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets of the EKS cluster (output private_subnet_ids of terraform/aws/eks). Data services get one subnet per AZ."
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least two private subnets in different AZs are required (Aurora, MSK and EFS need two AZs)."
  }
}

variable "client_security_group_ids" {
  description = "Extra security groups admitted on every data service (e.g. the EKS node security group). The private subnets' CIDRs are always admitted, so pods on Karpenter nodes reach the data services without this."
  type        = list(string)
  default     = []
}

variable "provision_strategy" {
  description = "min | ha | max, as in terraform/aws/eks. Controls Aurora deletion protection (off for min, on for ha/max); the Aurora instances per cluster come from aurora_clusters."
  type        = string
  default     = "min"
  validation {
    condition     = contains(["min", "ha", "max"], var.provision_strategy)
    error_message = "provision_strategy must be one of: min, ha, max"
  }
}

# ---------------------------------------------------------------- KMS

variable "kms_keys" {
  description = <<-EOT
    Customer-managed KMS keys, keyed by stable name (alias "alias/<cluster>-<key>").
    Aurora, ElastiCache, EFS, Secrets Manager and MSK use the key named by data_kms_key.
    Add a key here to give a service its own.
  EOT
  type = map(object({
    description             = optional(string)
    deletion_window_in_days = optional(number, 30)
    enable_key_rotation     = optional(bool, true)
    tags                    = optional(map(string), {})
  }))
  default = { data = {} }
}

variable "data_kms_key" {
  description = "Key in kms_keys used to encrypt the data services."
  type        = string
  default     = "data"
}

# ---------------------------------------------------------------- Aurora

variable "aurora" {
  description = <<-EOT
    Settings shared by every Aurora PostgreSQL Serverless v2 cluster, matching the SaaS
    clusters (prod-euc1-cluster-api, prod-aps1-cluster-api) incl. port 3306. The clusters
    and their sizing are in aurora_clusters. Each cluster's master password is generated
    and rotated by RDS in Secrets Manager (see output aurora_clusters). Per-service
    databases/roles are created by the installer afterwards, not here.
      engine_version        aurora-postgresql version at creation (minor upgrades then applied by AWS)
      parameters            cluster parameter group entries keyed by parameter name (default: SaaS's
                            pgaudit + pg_stat_statements + logical replication; static ones need a reboot,
                            which the aws-data phase does when AWS reports pending-reboot)
      monitoring_interval   Enhanced Monitoring seconds (0 = off); creates <cluster>-rds-monitoring-role
      data_api_enabled      RDS Data API (HTTP endpoint)
      preferred_*_window    UTC
  EOT
  type = object({
    enabled                 = optional(bool, true)
    engine_version          = optional(string, "17.11")
    parameter_group_family  = optional(string, "aurora-postgresql17")
    port                    = optional(number, 3306)
    master_username         = optional(string, "postgres")
    backup_retention_period = optional(number, 7)
    deletion_protection     = optional(bool)
    parameters = optional(map(object({
      value        = string
      apply_method = optional(string, "pending-reboot")
      })), {
      "shared_preload_libraries" = { value = "pg_stat_statements,pgaudit" }
      "pgaudit.log"              = { value = "write,ddl", apply_method = "immediate" }
      "rds.logical_replication"  = { value = "1" }
    })
    iam_database_authentication_enabled = optional(bool, true)
    performance_insights_enabled        = optional(bool, true)
    monitoring_interval                 = optional(number, 60)
    data_api_enabled                    = optional(bool, true)
    preferred_backup_window             = optional(string, "03:00-04:00")
    preferred_maintenance_window        = optional(string, "mon:04:00-mon:05:00")
  })
  default = {}
}

variable "aurora_clusters" {
  description = <<-EOT
    Aurora PostgreSQL clusters, keyed by stable name. Default: ONE shared cluster, like the
    SaaS regions, holding every database (platform services, frontend, iris and bifrost);
    which cluster a database lives in is set per database in charts/straiker-data. The key
    "platform" is the cluster id "<cluster>-aurora"; any other key is "<cluster>-aurora-<key>".
      min/max_capacity   ACUs (0.5 ACU = 1 GiB); scales up on load (default 2-16; SaaS runs 0.5-60;
                         changing it later is an online update, no restart)
      instances          keyed by stable name; "writer-1" is created first and becomes the writer.
                         Default (SaaS): a writer plus a reader in another AZ, both promotion tier 1.
  EOT
  type = map(object({
    min_capacity = number
    max_capacity = number
    instances = optional(map(object({
      instance_class    = optional(string, "db.serverless")
      availability_zone = optional(string)
      promotion_tier    = optional(number, 1)
    })))
  }))
  default = {
    platform = { min_capacity = 2, max_capacity = 16 }
  }

  validation {
    condition     = contains(keys(var.aurora_clusters), "platform")
    error_message = "aurora_clusters must contain the key \"platform\" (the frontend and platform services connect there)."
  }
}

# ---------------------------------------------------------------- ElastiCache

variable "caches" {
  description = <<-EOT
    ElastiCache Serverless caches, keyed by stable name (cache name "<cluster>-<key>").
      engine / major_engine_version   "redis" + "7" (diagram), or "valkey" + "8"
      max_data_storage_gb / max_ecpu_per_second   cost caps; null = unlimited
  EOT
  type = map(object({
    description              = optional(string, "")
    engine                   = optional(string, "redis")
    major_engine_version     = optional(string, "7")
    max_data_storage_gb      = optional(number)
    max_ecpu_per_second      = optional(number)
    snapshot_retention_limit = optional(number, 1)
    tags                     = optional(map(string), {})
  }))
  default = { main = {} }
  validation {
    condition     = alltrue([for c in values(var.caches) : contains(["redis", "valkey"], c.engine)])
    error_message = "engine must be \"redis\" or \"valkey\"."
  }
}

variable "redis_replication_groups" {
  description = <<-EOT
    Node-based ElastiCache replication groups (group "<cluster>-<key>-redis"), keyed by stable name.
    Matches the SaaS iris cache: Valkey, multi-AZ with automatic failover, TLS + AUTH token. The token is
    generated here (kept in state, like SaaS) and published to Secrets Manager as "<cluster>/<key>/redis"
    ({host, port, auth_token, tls, url}). Default: one group for iris (ascend); Defend keeps `caches.main`.
  EOT
  type = map(object({
    engine_version           = optional(string, "8.1")
    node_type                = optional(string, "cache.m6g.large")
    num_cache_clusters       = optional(number, 2)
    snapshot_retention_limit = optional(number, 1)
    secret_recovery_window   = optional(number, 7)
    tags                     = optional(map(string), {})
  }))
  default = { iris = {} }
  validation {
    condition     = alltrue([for g in values(var.redis_replication_groups) : g.num_cache_clusters >= 1])
    error_message = "num_cache_clusters must be >= 1 (use >= 2 for failover)."
  }
}

# ---------------------------------------------------------------- OpenSearch

variable "opensearch_domains" {
  description = <<-EOT
    Amazon OpenSearch Service domains, keyed by stable name (domain "<cluster>-oss" for key "main",
    else "<cluster>-oss-<key>"). SaaS shape (OpenSearch 3.x here; SaaS runs 2.19; AWS offers no 3.6): VPC, fine-grained access control with an internal
    master user, encryption at rest (data key) + node-to-node, HTTPS TLS 1.2, gp3. The master password is
    generated here (kept in state, like the Redis token) and published in Secrets Manager
    "<cluster>/opensearch/<key>" as {username, password, endpoint, url}.
    Size by provision_strategy unless set: min = one t3.small.search node; ha/max = 3 data + 3 dedicated master
    nodes across (up to) 3 AZs, as SaaS Frankfurt (r7g.large / m7g.large; max: r7g.xlarge).
  EOT
  type = map(object({
    engine_version          = optional(string, "OpenSearch_3.7")
    instance_type           = optional(string)
    instance_count          = optional(number)
    dedicated_master_type   = optional(string)
    dedicated_master_count  = optional(number, 3)
    availability_zone_count = optional(number)
    volume_size             = optional(number)
    master_user_name        = optional(string, "admin")
    secret_recovery_window  = optional(number, 7)
    tags                    = optional(map(string), {})
  }))
  default = { main = {} }
}

variable "create_opensearch_service_linked_role" {
  description = "Create AWSServiceRoleForAmazonOpenSearchService (VPC domains need it; it exists once any domain was created in the account). The installer sets this from a one-time check and remembers it."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- MSK

variable "msk_clusters" {
  description = <<-EOT
    MSK Serverless clusters, keyed by stable name (cluster "<cluster>-<key>").
    Serverless supports SASL/IAM only (port 9098); services use bus.sasl.mechanism=aws_msk_iam
    with Pod Identity. Topics are created by the installer (a Job), not here.
  EOT
  type = map(object({
    tags = optional(map(string), {})
  }))
  default = { bus = {} }
}

# ---------------------------------------------------------------- EFS

variable "efs_file_systems" {
  description = <<-EOT
    EFS file systems, keyed by stable name (Name tag "<cluster>-<key>"). One mount target per AZ.
    Default: shared model cache for the GPU pods (charts/straiker-system efs.*).
  EOT
  type = map(object({
    performance_mode                = optional(string, "generalPurpose")
    throughput_mode                 = optional(string, "elastic")
    provisioned_throughput_in_mibps = optional(number)
    transition_to_ia                = optional(string, "AFTER_30_DAYS")
    tags                            = optional(map(string), {})
  }))
  default = { models = {} }
}

# ---------------------------------------------------------------- Secrets Manager

variable "secrets" {
  description = <<-EOT
    Secrets Manager secrets, keyed by stable name (secret "<cluster>/<key>"), encrypted with the data key.
    generated_keys: JSON keys filled with a random password at creation (value is then
    ignored by Terraform, so later edits/rotation are not overwritten). Empty = container only.
  EOT
  type = map(object({
    description             = optional(string)
    generated_keys          = optional(list(string), [])
    password_length         = optional(number, 32)
    recovery_window_in_days = optional(number, 7)
    tags                    = optional(map(string), {})
  }))
  default = {}
}

# ---------------------------------------------------------------- S3

variable "s3_buckets" {
  description = <<-EOT
    Application buckets, keyed by stable name (bucket "<cluster>-<account>-<key>"), SSE-KMS with the
    data key, TLS-only, no public access. Default: grid's transcript artifacts bucket (read by grid;
    written by the Defend compactor, which on-prem has no equivalent of yet - empty = skeleton-only transcripts).
  EOT
  type = map(object({
    versioning    = optional(bool, false)
    force_destroy = optional(bool, false)
    tags          = optional(map(string), {})
  }))
  default = { "grid-artifacts" = {} }
}

# ---------------------------------------------------------------- DynamoDB

variable "dynamodb_tables" {
  description = <<-EOT
    DynamoDB tables, keyed by stable name (table "<cluster>-<key>"): pk/sk + the apiKey-index GSI the
    api-gateway queries. Default: the gateway's environment table. null deletion_protection = by provision_strategy.
  EOT
  type = map(object({
    deletion_protection = optional(bool)
    tags                = optional(map(string), {})
  }))
  default = { environment = {} }
}

# ---------------------------------------------------------------- Pod Identity

variable "pod_identities" {
  description = <<-EOT
    IAM roles for platform workloads, keyed by stable name (role "<cluster>-<key>"), bound to a
    service account with EKS Pod Identity.
      msk_clusters    keys of msk_clusters this role may use (connect, read/write topics + groups)
      secret_keys     keys of secrets readable (plus the Aurora master secret when aurora_master_secret = true)
      kms_use         allow use of the data KMS key (decrypt secrets, EFS, MSK)
      s3_read/s3_write       keys of s3_buckets readable (Get/List) / writable (Put/Delete/multipart)
      secret_prefixes_rw     Secrets Manager name prefixes this role may fully manage (get/put/create/delete),
                             e.g. "<cluster>/platform/" (databridge sinks, connect and integration credentials)
      secret_prefixes_read   Secrets Manager name prefixes this role may read (get/describe)
      dynamodb_query         keys of dynamodb_tables whose apiKey-index this role may query
      ses_send               allow ses:SendEmail/SendRawEmail on identities in this account (connect email)
      assume_roles           allow sts:AssumeRole on any role (databridge sink probes/delivery into customer accounts)
      policy_json            extra inline policy document (JSON)
    The EKS cluster must already exist (aws_eks_pod_identity_association needs it).
  EOT
  type = map(object({
    namespace            = string
    service_account      = string
    msk_clusters         = optional(list(string), [])
    secret_keys          = optional(list(string), [])
    aurora_master_secret = optional(bool, false)
    kms_use              = optional(bool, true)
    s3_read              = optional(list(string), [])
    s3_write             = optional(list(string), [])
    secret_prefixes_rw   = optional(list(string), [])
    secret_prefixes_read = optional(list(string), [])
    dynamodb_query       = optional(list(string), [])
    ses_send             = optional(bool, false)
    assume_roles         = optional(bool, false)
    policy_json          = optional(string)
    tags                 = optional(map(string), {})
  }))
  default = {}
}

variable "tags" {
  description = "Extra tags on every resource."
  type        = map(string)
  default     = {}
}
