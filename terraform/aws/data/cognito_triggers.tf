# Cognito Lambda triggers, as SaaS (infra platform/cognito-environment-api/tf: lambda.tf, iam.tf; the code is foundation's
# environment-api, one zip, one handler per trigger). Off unless var.cognito_triggers carries a lambda_code object, so an
# install without it behaves exactly as before.
#
#   pre-authentication, pre-sign-up, pre-token-generation   resolve the user in the platform (foundation's /authz/resolve, through an
#                                                           internal load balancer) and fall back to DynamoDB; the pre-token trigger
#                                                           puts straikerId, role and scopes into the token
#   define / create / verify auth challenge                 the CUSTOM_AUTH flow behind the gateway's PAT -> token exchange
#
# The triggers that call foundation run in the VPC (var.cognito_trigger_network): the private subnets (a NAT route, they still call
# DynamoDB, Cognito and Secrets Manager) and a security group that foundation's internal load balancer admits.
#
# Roles are scoped to this stack (SaaS attaches AmazonDynamoDBFullAccess and AmazonCognitoPowerUser): DynamoDB on the one table,
# Cognito admin calls on this pool only.

locals {
  triggers_on = var.cognito_triggers != null && try(var.cognito_triggers.lambda_code, null) != null && contains(keys(var.cognito_pools), "main")
  trg         = local.triggers_on ? var.cognito_triggers : null

  # Triggers that resolve users through the platform (they get the platform env and, when set, the VPC attachment).
  platform_triggers = toset(["pre-authentication", "pre-sign-up", "pre-token-generation"])

  # The VPC attachment of the triggers that call foundation (null = not attached).
  trigger_vpc = var.cognito_trigger_network ? {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.cognito_trigger[0].id]
  } : null

  trigger_role_keys = local.triggers_on ? toset(["dynamo-read", "sign-up"]) : toset([])

  trigger_table = local.triggers_on ? aws_dynamodb_table.this[local.trg.dynamodb_table].name : ""

  # Secret values by reference (the handler reads <NAME>_SECRET_ID and fetches a plain-string secret): never a value in the
  # function's environment or in state.
  trigger_secret_env = local.triggers_on ? merge(
    local.trg.pat_exchange_assertion_secret != null ? { PAT_EXCHANGE_ASSERTION_SECRET_SECRET_ID = local.trg.pat_exchange_assertion_secret } : {},
    local.trg.platform_internal_s2s_secret != null ? { PLATFORM_INTERNAL_S2S_API_KEY_SECRET_ID = local.trg.platform_internal_s2s_secret } : {},
  ) : {}

  trigger_platform_env = local.triggers_on ? merge(
    {
      PLATFORM_INTERNAL_BASE_URL = try(local.trg.platform_authz.internal_base_url, "")
      PLATFORM_AUTHZ_ENABLED     = try(local.trg.platform_authz.enabled, "")
      PLATFORM_AUTHZ_TIMEOUT_MS  = try(local.trg.platform_authz.timeout_ms, "")
    },
    local.trg.platform_internal_s2s_secret != null ? { PLATFORM_INTERNAL_S2S_API_KEY_SECRET_ID = local.trg.platform_internal_s2s_secret } : {},
    local.trg.operator_domains != "" ? { OPERATOR_DOMAINS = local.trg.operator_domains } : {},
  ) : {}

  trigger_secret_ids = local.triggers_on ? compact([local.trg.pat_exchange_assertion_secret, local.trg.platform_internal_s2s_secret]) : []

  triggers = local.triggers_on ? {
    pre-authentication = {
      handler = "pre-authentication.handler"
      role    = aws_iam_role.cognito_trigger["dynamo-read"].arn
      env     = merge({ REGION = var.region, DYNAMODB_TABLE_NAME = local.trigger_table }, local.trigger_platform_env)
    }
    pre-sign-up = {
      handler = "pre-sign-up.handler"
      role    = aws_iam_role.cognito_trigger["sign-up"].arn
      env     = merge({ REGION = var.region, DYNAMODB_TABLE_NAME = local.trigger_table }, local.trigger_platform_env)
    }
    pre-token-generation = {
      handler = "pre-token-generation.handler"
      role    = aws_iam_role.cognito_trigger["sign-up"].arn
      env = merge({
        REGION              = var.region
        DYNAMODB_TABLE_NAME = local.trigger_table
        # The operator role is only issued to the admin app's client; there is none on-prem, so no client matches (a name that is
        # set avoids the handler's "not configured" error on every token).
        ADMIN_COGNITO_CLIENT_NAME = "${local.cognito_name["main"]}-admin"
      }, local.trigger_platform_env, local.trigger_secret_env)
    }
    define-auth-challenge = {
      handler = "define-auth-challenge.handler"
      role    = aws_iam_role.cognito_trigger["dynamo-read"].arn
      env     = { REGION = var.region }
    }
    create-auth-challenge = {
      handler = "create-auth-challenge.handler"
      role    = aws_iam_role.cognito_trigger["dynamo-read"].arn
      env     = { REGION = var.region }
    }
    verify-auth-challenge = {
      handler = "verify-auth-challenge.handler"
      role    = aws_iam_role.cognito_trigger["dynamo-read"].arn
      env     = merge({ REGION = var.region }, local.trigger_secret_env)
    }
  } : {}
}

# The zip's version, so a re-upload of the same key still redeploys exactly what is in the bucket now.
data "aws_s3_object" "cognito_trigger_zip" {
  count = local.triggers_on ? 1 : 0

  bucket = local.trg.lambda_code.bucket
  key    = local.trg.lambda_code.key
}

resource "aws_cloudwatch_log_group" "cognito_trigger" {
  for_each = local.triggers

  name              = "/aws/lambda/${local.name}-${each.key}"
  retention_in_days = local.trg.log_retention_days
  tags              = local.common_tags
}

data "aws_iam_policy_document" "cognito_trigger_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Two roles, as SaaS: dynamo-read (pre-authentication and the CUSTOM_AUTH triggers) and sign-up (pre-sign-up and pre-token-generation:
# links federated users, edits Cognito users, writes the last-login stamp).
resource "aws_iam_role" "cognito_trigger" {
  for_each = local.trigger_role_keys

  name               = "${local.name}-cognito-${each.key}-role"
  description        = "Cognito trigger Lambdas of ${local.name} (${each.key})"
  assume_role_policy = data.aws_iam_policy_document.cognito_trigger_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cognito_trigger_basic" {
  for_each = local.trigger_role_keys

  role       = aws_iam_role.cognito_trigger[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Network interfaces for the triggers that run in the VPC.
resource "aws_iam_role_policy_attachment" "cognito_trigger_vpc" {
  for_each = local.triggers_on && local.trigger_vpc != null ? local.trigger_role_keys : toset([])

  role       = aws_iam_role.cognito_trigger[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "cognito_trigger" {
  for_each = local.trigger_role_keys

  statement {
    sid       = "DynamoDb"
    actions   = each.key == "sign-up" ? ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:BatchGetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"] : ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:BatchGetItem"]
    resources = [aws_dynamodb_table.this[local.trg.dynamodb_table].arn, "${aws_dynamodb_table.this[local.trg.dynamodb_table].arn}/index/*"]
  }

  dynamic "statement" {
    for_each = each.key == "sign-up" ? [1] : []
    content {
      sid = "CognitoUsers"
      actions = [
        "cognito-idp:AdminGetUser", "cognito-idp:AdminUpdateUserAttributes", "cognito-idp:AdminLinkProviderForUser",
        "cognito-idp:AdminCreateUser", "cognito-idp:AdminSetUserPassword", "cognito-idp:ListUsers",
        "cognito-idp:DescribeUserPoolClient", "cognito-idp:AdminListGroupsForUser",
      ]
      resources = [aws_cognito_user_pool.this["main"].arn]
    }
  }

  dynamic "statement" {
    for_each = length(local.trigger_secret_ids) > 0 ? [1] : []
    content {
      sid       = "TriggerSecrets"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [for id in local.trigger_secret_ids : "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${id}-??????"]
    }
  }

  # The secrets are encrypted with the stack's secrets key.
  dynamic "statement" {
    for_each = length(local.trigger_secret_ids) > 0 ? [1] : []
    content {
      sid       = "TriggerSecretsKey"
      actions   = ["kms:Decrypt"]
      resources = [local.secrets_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "cognito_trigger" {
  for_each = local.trigger_role_keys

  name   = "cognito-trigger"
  role   = aws_iam_role.cognito_trigger[each.key].id
  policy = data.aws_iam_policy_document.cognito_trigger[each.key].json
}

resource "aws_lambda_function" "cognito_trigger" {
  for_each = local.triggers

  function_name     = "${local.name}-${each.key}"
  description       = "Cognito ${each.key} trigger (${local.cognito_name["main"]})"
  role              = each.value.role
  handler           = each.value.handler
  runtime           = local.trg.runtime
  architectures     = ["x86_64"]
  memory_size       = 256
  timeout           = 3
  s3_bucket         = local.trg.lambda_code.bucket
  s3_key            = local.trg.lambda_code.key
  s3_object_version = data.aws_s3_object.cognito_trigger_zip[0].version_id

  environment {
    variables = each.value.env
  }

  dynamic "vpc_config" {
    for_each = local.trigger_vpc != null && contains(local.platform_triggers, each.key) ? [local.trigger_vpc] : []
    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  tags = local.common_tags

  # Not on aws_iam_role_policy.cognito_trigger: the sign-up policy names the pool, and the pool names these functions (a cycle). The
  # policy attaches right after; the handlers run only when Cognito calls them.
  depends_on = [
    aws_cloudwatch_log_group.cognito_trigger,
    aws_iam_role_policy_attachment.cognito_trigger_basic,
    aws_iam_role_policy_attachment.cognito_trigger_vpc,
  ]
}

resource "aws_lambda_permission" "cognito_trigger" {
  for_each = local.triggers

  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cognito_trigger[each.key].function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this["main"].arn
}

#------------------------------------------------------------------------------
# Network for the triggers and for foundation's internal load balancer (var.cognito_trigger_network)
#------------------------------------------------------------------------------

resource "aws_security_group" "cognito_trigger" {
  count = var.cognito_trigger_network ? 1 : 0

  name        = "${local.name}-cognito-triggers"
  description = "Cognito trigger Lambdas of ${local.name}: outbound only"
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${local.name}-cognito-triggers" })

  egress {
    description = "DynamoDB, Cognito, Secrets Manager (NAT) and the foundation internal load balancer"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The load balancer's own security group (annotation aws-load-balancer-security-groups): it admits only the triggers. The controller
# adds the rule that lets this group reach the pods.
resource "aws_security_group" "foundation_nlb" {
  count = var.cognito_trigger_network ? 1 : 0

  name = "${local.name}-foundation-internal-nlb"
  # EC2 security group descriptions allow only a-zA-Z0-9 and . _-:/()#,@[]+=&;{}!$* (no apostrophes).
  description = "Foundation internal load balancer of ${local.name}: the Cognito triggers only"
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${local.name}-foundation-internal-nlb" })

  ingress {
    description     = "HTTP from the Cognito trigger Lambdas"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.cognito_trigger[0].id]
  }
  egress {
    description = "To the pods"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.subnet_cidrs
  }
}

#------------------------------------------------------------------------------
# The client of the PAT -> token exchange (the gateway's u2s-client-id), as SaaS: no client secret
#------------------------------------------------------------------------------

# The gateway starts CUSTOM_AUTH (InitiateAuth, then RespondToAuthChallenge) without SECRET_HASH, which a client with a secret requires,
# so this cannot be the console's frontend client (confidential: its login uses the secret). A client of its own, public and limited to
# the custom-auth flow; it cannot sign anyone in without the gateway-signed assertion that verify-auth-challenge checks.
resource "aws_cognito_user_pool_client" "u2s" {
  count = var.cognito_trigger_network && contains(keys(var.cognito_pools), "main") ? 1 : 0

  name         = "${local.cognito_name["main"]}-u2s"
  user_pool_id = aws_cognito_user_pool.this["main"].id

  generate_secret                      = false
  explicit_auth_flows                  = ["ALLOW_CUSTOM_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_oauth_flows_user_pool_client = false
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
}
