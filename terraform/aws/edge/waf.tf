# AWS WAF (v2, REGIONAL) in front of the edge ALB -- edgeType=alb or xalb (var.enable_waf, set by
# install-straiker.sh's phase_edge_infra). The Web ACL is attached by the AWS Load Balancer Controller through the
# alb.ingress.kubernetes.io/wafv2-acl-arn annotation on charts/straiker-edge's Ingress (its IAM policy already allows
# wafv2:AssociateWebACL), so the association follows the ALB's own lifecycle and needs no ALB ARN here.
#
# Rules, in evaluation order:
#   0..n  host allowlists (var.waf_host_allowlists): a request for <host> from outside its CIDRs is blocked. This is
#         how the console and the API gateway get different source ranges on ONE shared ALB (the controller's
#         inbound-cidrs annotation is ALB-wide).
#   10    rate limit per source IP (var.waf_rate_limit requests / 5 minutes; 0 = no rate rule).
#   20+   AWS managed rule groups (var.waf_managed_rule_groups).
#
# Request BODY rules are set to COUNT by default, not BLOCK: the Defend detect API's whole job is to receive prompts
# that contain attack strings (XSS, path traversal, Log4Shell, SSRF payloads, ...) and long bodies, so blocking on body
# content would reject the product's own traffic. Headers, URI and query string rules still block. Counted matches
# are in the WAF log, so a customer can tighten this later per rule.

locals {
  waf_name = "${var.cluster_name}-edge"

  # Stable priority per host allowlist (sorted by host name).
  waf_hosts = { for i, h in sort(keys(var.waf_host_allowlists)) : h => i }
}

resource "aws_wafv2_ip_set" "host_allowlist" {
  for_each = var.enable_waf ? var.waf_host_allowlists : {}

  name               = "${local.waf_name}-${replace(each.key, ".", "-")}"
  description        = "Source ranges allowed to reach ${each.key}"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = each.value

  tags = local.common_tags
}

resource "aws_wafv2_web_acl" "edge" {
  count = var.enable_waf ? 1 : 0

  name        = local.waf_name
  description = "Straiker edge ALB (${var.cluster_name}): host allowlists, rate limit, AWS managed rules"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = var.waf_host_allowlists
    content {
      name     = "allowlist-${replace(rule.key, ".", "-")}"
      priority = local.waf_hosts[rule.key]

      action {
        block {}
      }

      statement {
        and_statement {
          statement {
            byte_match_statement {
              search_string         = lower(rule.key)
              positional_constraint = "EXACTLY"
              field_to_match {
                single_header {
                  name = "host"
                }
              }
              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = aws_wafv2_ip_set.host_allowlist[rule.key].arn
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "allowlist-${replace(rule.key, ".", "-")}"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.waf_rate_limit > 0 ? [1] : []
    content {
      name     = "rate-limit-per-ip"
      priority = 10 + length(var.waf_host_allowlists)

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = var.waf_rate_limit
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "rate-limit-per-ip"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.waf_managed_rule_groups
    content {
      name     = rule.key
      priority = 20 + length(var.waf_host_allowlists) + rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = rule.value.vendor

          dynamic "rule_action_override" {
            for_each = toset(rule.value.count_rules)
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.waf_name
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

# WAF logs in CloudWatch Logs (the group name must start with "aws-waf-logs-"). Credentials are redacted.
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf ? 1 : 0

  name              = "aws-waf-logs-${local.waf_name}"
  retention_in_days = var.waf_log_retention_days

  tags = local.common_tags
}

resource "aws_wafv2_web_acl_logging_configuration" "edge" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.edge[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    single_header {
      name = "x-api-key"
    }
  }
}
