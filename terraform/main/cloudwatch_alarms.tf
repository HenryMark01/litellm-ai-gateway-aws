# ============================================================================
# CloudWatch Alarms for LiteLLM Infrastructure
# ============================================================================
# This file creates CloudWatch alarms for critical metrics monitoring:
# - ECS CPU and memory utilization
# - ALB 5XX error rate
# - ALB request latency
#
# ============================================================================

# ----------------------------------------------------------------------------
# Local Values
# ----------------------------------------------------------------------------

locals {
  # Determine the SNS topic ARN to use for alarm notifications
  # Use provided ARN if available, otherwise create a new topic
  alarm_sns_topic_arn = var.alarm_sns_topic_arn != "" ? var.alarm_sns_topic_arn : (
    var.enable_cloudwatch_alarms ? aws_sns_topic.alarms[0].arn : ""
  )

  # ECS cluster and service names follow the module naming convention
  ecs_cluster_name     = module.litellm.ecs_cluster
  gateway_service_name = "${var.tenant}-litellm-${var.environment}-gateway"

  # Extract ALB suffix from the ALB DNS name for CloudWatch dimensions
  # ALB DNS format: name-1234567890.region.elb.amazonaws.com
  # CloudWatch expects: app/name/1234567890
  alb_arn_suffix = join("/", [
    "app",
    "${var.tenant}-litellm-${var.environment}",
    element(split("-", element(split(".", module.litellm.alb_dns_name), 0)), length(split("-", element(split(".", module.litellm.alb_dns_name), 0))) - 1)
  ])
}

# ----------------------------------------------------------------------------
# SNS Topic for Alarm Notifications (Optional)
# ----------------------------------------------------------------------------
# Creates an SNS topic when alarm_sns_topic_arn is not provided
# ----------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  count = var.enable_cloudwatch_alarms && var.alarm_sns_topic_arn == "" ? 1 : 0

  name = "${var.tenant}-litellm-${var.environment}-alarms"

  tags = merge(var.additional_tags, {
    Name        = "${var.tenant}-litellm-${var.environment}-alarms"
    Environment = var.environment
    Purpose     = "CloudWatch alarm notifications"
  })
}

# ----------------------------------------------------------------------------
# ECS CPU Utilization Alarm (Gateway Service)
# ----------------------------------------------------------------------------
# Monitors CPU utilization for the Gateway ECS service
# Triggers when CPU exceeds threshold for sustained period
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "gateway_cpu_high" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.tenant}-litellm-${var.environment}-gateway-cpu-high"
  alarm_description   = "Gateway service CPU utilization exceeds ${var.cpu_alarm_threshold}% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = local.ecs_cluster_name
    ServiceName = local.gateway_service_name
  }

  alarm_actions = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []
  ok_actions    = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []

  tags = merge(var.additional_tags, {
    Name        = "${var.tenant}-litellm-${var.environment}-gateway-cpu-high"
    Environment = var.environment
    Service     = "gateway"
    MetricType  = "cpu"
  })
}

# ----------------------------------------------------------------------------
# ECS Memory Utilization Alarm (Gateway Service)
# ----------------------------------------------------------------------------
# Monitors memory utilization for the Gateway ECS service
# Triggers when memory exceeds threshold for sustained period
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "gateway_memory_high" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.tenant}-litellm-${var.environment}-gateway-memory-high"
  alarm_description   = "Gateway service memory utilization exceeds ${var.memory_alarm_threshold}% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = var.memory_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = local.ecs_cluster_name
    ServiceName = local.gateway_service_name
  }

  alarm_actions = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []
  ok_actions    = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []

  tags = merge(var.additional_tags, {
    Name        = "${var.tenant}-litellm-${var.environment}-gateway-memory-high"
    Environment = var.environment
    Service     = "gateway"
    MetricType  = "memory"
  })
}

# ----------------------------------------------------------------------------
# ALB 5XX Error Rate Alarm
# ----------------------------------------------------------------------------
# Monitors the 5XX error rate on the Application Load Balancer
# Uses metric math to calculate error percentage
# Triggers when error rate exceeds 5% over 5 minutes
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx_error_rate" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.tenant}-litellm-${var.environment}-alb-5xx-error-rate"
  alarm_description   = "ALB 5XX error rate exceeds 5% over 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  # Use metric math to calculate error rate percentage
  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, (errors / requests) * 100, 0)"
    label       = "5XX Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      metric_name = "HTTPCode_ELB_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"

      dimensions = {
        LoadBalancer = local.alb_arn_suffix
      }
    }
  }

  metric_query {
    id = "target_errors"

    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"

      dimensions = {
        LoadBalancer = local.alb_arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"

    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"

      dimensions = {
        LoadBalancer = local.alb_arn_suffix
      }
    }
  }

  alarm_actions = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []
  ok_actions    = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []

  tags = merge(var.additional_tags, {
    Name        = "${var.tenant}-litellm-${var.environment}-alb-5xx-error-rate"
    Environment = var.environment
    Service     = "alb"
    MetricType  = "error_rate"
  })
}

# ----------------------------------------------------------------------------
# ALB Latency Alarm
# ----------------------------------------------------------------------------
# Monitors request response time on the Application Load Balancer
# Triggers when average latency exceeds threshold for sustained period
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_latency_high" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.tenant}-litellm-${var.environment}-alb-latency-high"
  alarm_description   = "ALB average response time exceeds ${var.latency_alarm_threshold_seconds} seconds for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = var.latency_alarm_threshold_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_arn_suffix
  }

  alarm_actions = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []
  ok_actions    = local.alarm_sns_topic_arn != "" ? [local.alarm_sns_topic_arn] : []

  tags = merge(var.additional_tags, {
    Name        = "${var.tenant}-litellm-${var.environment}-alb-latency-high"
    Environment = var.environment
    Service     = "alb"
    MetricType  = "latency"
  })
}
