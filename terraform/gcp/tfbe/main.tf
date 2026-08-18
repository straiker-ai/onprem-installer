terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  bucket_name = "${var.prefix}-tfstate-${var.region}-${var.project_id}"
}

resource "google_storage_bucket" "tfstate" {
  name     = local.bucket_name
  location = var.region
  project  = var.project_id

  # Mirrors terraform/aws/tfbe's aws_s3_bucket_versioning + force_destroy=false —
  # state history is worth keeping, and this bucket should never be torn down
  # by accident via a broad `terraform destroy` elsewhere.
  versioning {
    enabled = true
  }
  force_destroy = false

  uniform_bucket_level_access = true

  public_access_prevention = "enforced"
}

output "bucket_name" {
  value = local.bucket_name
}

output "region" {
  value = var.region
}

output "backend_config" {
  description = "Paste this backend block into s6r-onprem/versions.tf"
  value       = <<-EOT
    backend "gcs" {
      bucket = "${local.bucket_name}"
      prefix = "s6r-onprem"
    }
  EOT
}
