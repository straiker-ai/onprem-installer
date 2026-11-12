# Amazon SES sending domains (SaaS: a verified domain identity + DKIM + custom MAIL FROM + a TLS-only configuration
# set). Used by Cognito (no-reply@) and the connect service (notifications@).

locals {
  ses = {
    for k, d in var.ses_domains : k => merge(d, {
      mail_from = "${d.mail_from_subdomain}.${d.domain}"
      zone_id   = d.route53_zone_id != null ? d.route53_zone_id : (d.create_route53_zone ? aws_route53_zone.ses[k].zone_id : null)
    })
  }

  ses_dns = merge([
    for k, d in local.ses : (d.route53_zone_id == null && !d.create_route53_zone) ? {} : merge(
      { for i in range(3) : "${k}/dkim-${i}" => { zone = d.zone_id, name = "${aws_sesv2_email_identity.this[k].dkim_signing_attributes[0].tokens[i]}._domainkey.${d.domain}", type = "CNAME", records = ["${aws_sesv2_email_identity.this[k].dkim_signing_attributes[0].tokens[i]}.dkim.amazonses.com"] } },
      {
        "${k}/mail-from-mx"  = { zone = d.zone_id, name = d.mail_from, type = "MX", records = ["10 feedback-smtp.${var.region}.amazonses.com"] }
        "${k}/mail-from-spf" = { zone = d.zone_id, name = d.mail_from, type = "TXT", records = ["v=spf1 include:amazonses.com ~all"] }
        "${k}/dmarc"         = { zone = d.zone_id, name = "_dmarc.${d.domain}", type = "TXT", records = ["v=DMARC1; p=none;"] }
      },
    )
  ]...)
}

# A public zone for the domain when none exists in this account; delegate its name servers from the parent zone.
resource "aws_route53_zone" "ses" {
  for_each = { for k, d in var.ses_domains : k => d if d.create_route53_zone && d.route53_zone_id == null }

  name = each.value.domain
  tags = merge(local.common_tags, each.value.tags, { Name = each.value.domain })
}

resource "aws_sesv2_configuration_set" "this" {
  for_each = var.ses_domains

  configuration_set_name = "${local.name}-${each.key}-automated"

  delivery_options {
    tls_policy = "REQUIRE"
  }
  reputation_options {
    reputation_metrics_enabled = true
  }
  sending_options {
    sending_enabled = true
  }

  tags = merge(local.common_tags, each.value.tags)
}

resource "aws_sesv2_email_identity" "this" {
  for_each = var.ses_domains

  email_identity         = each.value.domain
  configuration_set_name = aws_sesv2_configuration_set.this[each.key].configuration_set_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }

  tags = merge(local.common_tags, each.value.tags, { Name = each.value.domain })
}

resource "aws_sesv2_email_identity_mail_from_attributes" "this" {
  for_each = var.ses_domains

  email_identity         = aws_sesv2_email_identity.this[each.key].email_identity
  mail_from_domain       = local.ses[each.key].mail_from
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "aws_route53_record" "ses" {
  for_each = local.ses_dns

  zone_id         = each.value.zone
  name            = each.value.name
  type            = each.value.type
  ttl             = 600
  records         = each.value.records
  allow_overwrite = true
}

resource "aws_iam_service_linked_role" "cognito_email" {
  count            = var.create_cognito_email_service_linked_role && local.cognito_ses ? 1 : 0
  aws_service_name = "email.cognito-idp.amazonaws.com"
}
