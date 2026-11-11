# Application buckets (the data tier's object storage), e.g. grid's transcript artifacts.
# Names are "<cluster>-<account>-<key>" (bucket names are global); SSE-KMS with the data key.

resource "aws_s3_bucket" "this" {
  for_each = var.s3_buckets

  bucket        = "${local.name}-${data.aws_caller_identity.current.account_id}-${each.key}"
  force_destroy = each.value.force_destroy

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}-${each.key}" })
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.s3_buckets

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = each.value.versioning ? "Enabled" : "Suspended"
  }
}

data "aws_iam_policy_document" "bucket_tls" {
  for_each = var.s3_buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this[each.key].arn, "${aws_s3_bucket.this[each.key].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.this[each.key].id
  policy = data.aws_iam_policy_document.bucket_tls[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
