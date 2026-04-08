###############################################################
# Route 53 Failover Routing + Health Checks
# Supports: active-active (weighted) and active-passive (failover)
###############################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "domain_name" {
  description = "Primary domain name (e.g., app.example.com)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID"
  type        = string
}

variable "primary_endpoint" {
  description = "Primary region load balancer DNS name"
  type        = string
}

variable "secondary_endpoint" {
  description = "Secondary (DR) region load balancer DNS name"
  type        = string
}

variable "dr_mode" {
  description = "DR mode: 'active-passive' or 'active-active'"
  type        = string
  default     = "active-passive"
  validation {
    condition     = contains(["active-passive", "active-active"], var.dr_mode)
    error_message = "dr_mode must be 'active-passive' or 'active-active'."
  }
}

variable "primary_weight" {
  description = "Traffic weight for primary (active-active mode only)"
  type        = number
  default     = 70
}

variable "health_check_path" {
  description = "HTTP path for health checks"
  type        = string
  default     = "/health"
}

variable "alarm_sns_arn" {
  description = "SNS ARN for health check failure alerts"
  type        = string
}

##################################################
# Health Checks
##################################################

resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_endpoint
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 10

  regions = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  tags = {
    Name        = "primary-health-check"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

resource "aws_route53_health_check" "secondary" {
  fqdn              = var.secondary_endpoint
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 10

  regions = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  tags = {
    Name        = "secondary-health-check"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

##################################################
# CloudWatch Alarms for Health Check Failures
##################################################

resource "aws_cloudwatch_metric_alarm" "primary_health_check_failed" {
  alarm_name          = "route53-primary-health-check-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Primary endpoint health check failing — DR failover may be triggered"
  alarm_actions       = [var.alarm_sns_arn]
  ok_actions          = [var.alarm_sns_arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }
}

##################################################
# DNS Records — Active-Passive Mode
##################################################

resource "aws_route53_record" "primary_failover" {
  count = var.dr_mode == "active-passive" ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id
  ttl             = 60

  records = [var.primary_endpoint]
}

resource "aws_route53_record" "secondary_failover" {
  count = var.dr_mode == "active-passive" ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier  = "secondary-dr"
  health_check_id = aws_route53_health_check.secondary.id
  ttl             = 60

  records = [var.secondary_endpoint]
}

##################################################
# DNS Records — Active-Active Mode (Weighted)
##################################################

resource "aws_route53_record" "primary_weighted" {
  count = var.dr_mode == "active-active" ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  weighted_routing_policy {
    weight = var.primary_weight
  }

  set_identifier  = "primary-weighted"
  health_check_id = aws_route53_health_check.primary.id
  ttl             = 60

  records = [var.primary_endpoint]
}

resource "aws_route53_record" "secondary_weighted" {
  count = var.dr_mode == "active-active" ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  weighted_routing_policy {
    weight = 100 - var.primary_weight
  }

  set_identifier  = "secondary-weighted"
  health_check_id = aws_route53_health_check.secondary.id
  ttl             = 60

  records = [var.secondary_endpoint]
}

##################################################
# Outputs
##################################################

output "primary_health_check_id" {
  value       = aws_route53_health_check.primary.id
  description = "Route 53 health check ID for primary endpoint"
}

output "secondary_health_check_id" {
  value       = aws_route53_health_check.secondary.id
  description = "Route 53 health check ID for secondary endpoint"
}
