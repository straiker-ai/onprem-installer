# Amazon Cognito user pool for the frontend's login (OIDC). SaaS: platform/cognito-environment-api/tf/cognito.tf,
# without its Lambda triggers (multi-tenant claims, PAT token exchange); the customer's identity provider (SAML, OIDC,
# Google, Facebook, Login with Amazon or Sign in with Apple) is federated in below instead of SaaS's fixed Google.

locals {
  cognito_ses_own      = contains(keys(var.ses_domains), "main")
  cognito_ses_existing = var.ses_existing != null
  cognito_ses          = var.cognito_use_ses && (local.cognito_ses_own || local.cognito_ses_existing)
  cognito_name         = { for k, _ in var.cognito_pools : k => k == "main" ? "${local.name}-pool" : "${local.name}-${k}-pool" }
}

resource "aws_cognito_user_pool" "this" {
  for_each = var.cognito_pools

  name                     = local.cognito_name[each.key]
  deletion_protection      = local.ha ? "ACTIVE" : "INACTIVE"
  mfa_configuration        = var.cognito_mfa
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  dynamic "software_token_mfa_configuration" {
    for_each = var.cognito_mfa == "OFF" ? [] : [1]
    content {
      enabled = true
    }
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  # Through the verified SES domain once it is ready (installer: cognito_use_ses); else Cognito's default sender.
  dynamic "email_configuration" {
    for_each = each.key == "main" && local.cognito_ses && local.cognito_ses_own ? [1] : []
    content {
      email_sending_account = "DEVELOPER"
      from_email_address    = "Straiker <${var.ses_domains["main"].sender_local_part}@${var.ses_domains["main"].domain}>"
      source_arn            = aws_sesv2_email_identity.this["main"].arn
      configuration_set     = aws_sesv2_configuration_set.this["main"].configuration_set_name
    }
  }
  # The customer's own SES identity (nothing created for it).
  dynamic "email_configuration" {
    for_each = each.key == "main" && local.cognito_ses && local.cognito_ses_existing ? [1] : []
    content {
      email_sending_account = "DEVELOPER"
      from_email_address    = "Straiker <${var.ses_existing.from_address}>"
      source_arn            = var.ses_existing.identity_arn
      configuration_set     = var.ses_existing.configuration_set
    }
  }
  dynamic "email_configuration" {
    for_each = each.key == "main" && local.cognito_ses ? [] : [1]
    content {
      email_sending_account = "COGNITO_DEFAULT"
    }
  }

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  tags = merge(local.common_tags, each.value.tags, { Name = local.cognito_name[each.key] })

  depends_on = [aws_iam_service_linked_role.cognito_email]

  lifecycle {
    # Cognito rejects changes to an existing attribute's schema; the provider would otherwise plan a replacement.
    ignore_changes = [schema]
  }
}

# The customer's identity provider, federated into the "main" pool (one per customer; type decides the details).
locals {
  sso_names = nonsensitive(toset(keys(var.cognito_identity_providers)))
  sso       = var.cognito_identity_providers

  sso_details = {
    for k in local.sso_names : k => (
      local.sso[k].type == "SAML" ? tomap({ for dk, dv in {
        MetadataURL  = local.sso[k].saml_metadata_url
        MetadataFile = local.sso[k].saml_metadata_url == null ? local.sso[k].saml_metadata_file : null
        IDPSignout   = "false"
      } : dk => dv if dv != null }) :
      local.sso[k].type == "OIDC" ? tomap({
        client_id                 = local.sso[k].client_id
        client_secret             = local.sso[k].client_secret
        attributes_request_method = "GET"
        oidc_issuer               = local.sso[k].oidc_issuer
        authorize_scopes          = "openid email profile"
      }) :
      local.sso[k].type == "Google" ? tomap({
        client_id        = local.sso[k].client_id
        client_secret    = local.sso[k].client_secret
        authorize_scopes = "openid email profile"
      }) :
      local.sso[k].type == "Facebook" ? tomap({
        client_id        = local.sso[k].client_id
        client_secret    = local.sso[k].client_secret
        authorize_scopes = "public_profile,email"
        api_version      = "v19.0"
      }) :
      local.sso[k].type == "LoginWithAmazon" ? tomap({
        client_id        = local.sso[k].client_id
        client_secret    = local.sso[k].client_secret
        authorize_scopes = "profile"
      }) :
      tomap({
        client_id        = local.sso[k].client_id
        team_id          = local.sso[k].apple_team_id
        key_id           = local.sso[k].apple_key_id
        private_key      = local.sso[k].apple_private_key
        authorize_scopes = "email name"
      })
    )
  }

  # Cognito needs a username mapping for everything but SAML (the provider's stable subject); email carries the login.
  sso_username_claim = {
    OIDC            = "sub"
    Google          = "sub"
    Facebook        = "id"
    LoginWithAmazon = "user_id"
    SignInWithApple = "sub"
  }
}

resource "aws_cognito_identity_provider" "sso" {
  for_each = local.sso_names

  user_pool_id  = aws_cognito_user_pool.this["main"].id
  provider_name = each.key
  provider_type = local.sso[each.key].type

  provider_details = local.sso_details[each.key]

  attribute_mapping = merge(
    {
      email = coalesce(
        local.sso[each.key].email_claim,
        local.sso[each.key].type == "SAML" ? "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" : "email",
      )
    },
    local.sso[each.key].type == "SAML" ? {} : { username = local.sso_username_claim[local.sso[each.key].type] },
    local.sso[each.key].type == "Google" ? { email_verified = "email_verified" } : {},
  )

  # Domain routing identifiers are for SAML / OIDC; the social providers are restricted by the frontend allow-list.
  idp_identifiers = contains(["SAML", "OIDC"], local.sso[each.key].type) ? local.sso[each.key].domains : []

}

resource "aws_cognito_user_pool_domain" "this" {
  for_each = var.cognito_pools

  domain       = each.key == "main" ? "straiker-${local.name}" : "straiker-${local.name}-${each.key}"
  user_pool_id = aws_cognito_user_pool.this[each.key].id
}

# Confidential client: the frontend's OIDC login needs a client secret (SaaS's client has none).
resource "aws_cognito_user_pool_client" "frontend" {
  for_each = var.cognito_pools

  name         = "${local.cognito_name[each.key]}-frontend"
  user_pool_id = aws_cognito_user_pool.this[each.key].id

  generate_secret = true
  # USER_PASSWORD_AUTH: the frontend's own email sign-in page (/login/password) calls Cognito directly, with the client secret.
  explicit_auth_flows                  = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = concat(["COGNITO"], each.key == "main" ? sort(tolist(local.sso_names)) : [])
  callback_urls                        = var.cognito_callback_urls
  logout_urls                          = [for u in var.cognito_callback_urls : replace(u, "/login/oidc/callback", "/login")]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  auth_session_validity                = 3
  id_token_validity                    = var.cognito_token_validity.id_minutes
  access_token_validity                = var.cognito_token_validity.access_minutes
  refresh_token_validity               = var.cognito_token_validity.refresh_hours

  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "hours"
  }

  depends_on = [aws_cognito_identity_provider.sso]
}

resource "aws_secretsmanager_secret" "cognito" {
  for_each = var.cognito_pools

  name                    = "${local.name}/cognito/${each.key}"
  description             = "${local.cognito_name[each.key]} OIDC client (issuer, client id/secret)"
  kms_key_id              = local.kms_key_arn
  recovery_window_in_days = 7

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}/cognito/${each.key}" })
}

resource "aws_secretsmanager_secret_version" "cognito" {
  for_each = var.cognito_pools

  secret_id = aws_secretsmanager_secret.cognito[each.key].id
  secret_string = jsonencode({
    issuer        = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this[each.key].id}"
    client_id     = aws_cognito_user_pool_client.frontend[each.key].id
    client_secret = aws_cognito_user_pool_client.frontend[each.key].client_secret
    domain        = "https://${aws_cognito_user_pool_domain.this[each.key].domain}.auth.${var.region}.amazoncognito.com"
    pool_id       = aws_cognito_user_pool.this[each.key].id
    region        = var.region
  })
}

# First admin's password (the user itself is created by the installer from --admin-email).
resource "random_password" "cognito_admin" {
  for_each = var.cognito_pools

  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_secretsmanager_secret" "cognito_admin" {
  for_each = var.cognito_pools

  name                    = "${local.name}/cognito/${each.key}-admin"
  description             = "${local.cognito_name[each.key]} first admin's password"
  kms_key_id              = local.kms_key_arn
  recovery_window_in_days = 7

  tags = merge(local.common_tags, each.value.tags, { Name = "${local.name}/cognito/${each.key}-admin" })
}

resource "aws_secretsmanager_secret_version" "cognito_admin" {
  for_each = var.cognito_pools

  secret_id     = aws_secretsmanager_secret.cognito_admin[each.key].id
  secret_string = jsonencode({ password = random_password.cognito_admin[each.key].result })

  lifecycle {
    # The installer rotates this password (--rotate-admin-password); Terraform only seeds the first value.
    ignore_changes = [secret_string]
  }
}
