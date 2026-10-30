variable "enable_https" {
  description = "Enable HTTPS only after the ACM certificate is issued and the TLS bundle secret is populated."
  type        = bool
  default     = false
}

variable "keep_legacy_http" {
  description = "Keep the existing restricted port 3000 rule during HTTPS cutover; disable after verification."
  type        = bool
  default     = true
}

variable "https_allowed_cidrs" {
  description = "Optional HTTPS source CIDRs. Empty keeps the existing allowed_cidr restriction. Review before using public or Cloudflare ranges."
  type        = list(string)
  default     = []
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for trendpointlabs.com (not a credential)."
  type        = string
}

variable "cloudflare_token_secret_arn" {
  description = "ARN of a Secrets Manager secret containing only the zone-scoped Cloudflare API token."
  type        = string
}

resource "aws_acm_certificate" "count" {
  domain_name       = "count.trendpointlabs.com"
  validation_method = "DNS"
  options { export = "ENABLED" }
  lifecycle { create_before_destroy = true }
}

output "acm_dns_validation" {
  description = "Add the returned CNAME record in Cloudflare as DNS only, then wait for ISSUED status."
  value       = aws_acm_certificate.count.domain_validation_options
}

resource "aws_secretsmanager_secret" "tls_bundle" {
  name        = "count/tls-bundle"
  description = "ACM exported certificate, encrypted private key, and passphrase for the Count task."
}

resource "aws_iam_role_policy" "execution_tls" {
  name = "count-read-tls-bundle"
  role = aws_iam_role.execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_secretsmanager_secret.tls_bundle.arn
  }] })
}

resource "aws_iam_role" "dns_reconcile" {
  name = "count-dns-reconcile"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}

resource "aws_iam_role_policy" "dns_reconcile" {
  role = aws_iam_role.dns_reconcile.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecs:ListTasks", "ecs:DescribeTasks"], Resource = "*" },
    { Effect = "Allow", Action = "ec2:DescribeNetworkInterfaces", Resource = "*" },
    { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = var.cloudflare_token_secret_arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.dns_reconcile.arn}:*" }
  ] })
}

resource "aws_cloudwatch_log_group" "dns_reconcile" {
  name              = "/aws/lambda/count-dns-reconcile"
  retention_in_days = 7
}

resource "aws_lambda_function" "dns_reconcile" {
  function_name    = "count-dns-reconcile"
  role             = aws_iam_role.dns_reconcile.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = "${path.module}/dns_reconcile.zip"
  source_code_hash = filebase64sha256("${path.module}/dns_reconcile.zip")
  timeout          = 30
  environment { variables = {
    CLUSTER_NAME                = aws_ecs_cluster.count.name
    SERVICE_NAME                = aws_ecs_service.count.name
    CLOUDFLARE_ZONE_ID          = var.cloudflare_zone_id
    CLOUDFLARE_HOSTNAME         = "count.trendpointlabs.com"
    CLOUDFLARE_TOKEN_SECRET_ARN = var.cloudflare_token_secret_arn
  } }
  depends_on = [aws_iam_role_policy.dns_reconcile]
}

resource "aws_cloudwatch_event_rule" "count_task_changes" {
  name = "count-task-state-changes"
  event_pattern = jsonencode({
    source = ["aws.ecs"], "detail-type" = ["ECS Task State Change"],
    detail = { clusterArn = [aws_ecs_cluster.count.arn], group = ["service:count"] }
  })
}

resource "aws_cloudwatch_event_rule" "dns_schedule" {
  name                = "count-dns-reconcile-schedule"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "dns_task_changes" {
  rule = aws_cloudwatch_event_rule.count_task_changes.name
  arn  = aws_lambda_function.dns_reconcile.arn
}

resource "aws_cloudwatch_event_target" "dns_schedule" {
  rule = aws_cloudwatch_event_rule.dns_schedule.name
  arn  = aws_lambda_function.dns_reconcile.arn
}

resource "aws_lambda_permission" "dns_task_changes" {
  statement_id  = "AllowCountTaskEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dns_reconcile.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.count_task_changes.arn
}

resource "aws_lambda_permission" "dns_schedule" {
  statement_id  = "AllowCountDnsSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dns_reconcile.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dns_schedule.arn
}

resource "aws_iam_role" "certificate_renewal" {
  name = "count-certificate-renewal"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
}

resource "aws_iam_role_policy" "certificate_renewal" {
  role = aws_iam_role.certificate_renewal.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["acm:ExportCertificate", "acm:DescribeCertificate"], Resource = aws_acm_certificate.count.arn },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"], Resource = aws_secretsmanager_secret.tls_bundle.arn },
    { Effect = "Allow", Action = "ecs:UpdateService", Resource = aws_ecs_service.count.id },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.certificate_renewal.arn}:*" }
  ] })
}

resource "aws_cloudwatch_log_group" "certificate_renewal" {
  name              = "/aws/lambda/count-certificate-renewal"
  retention_in_days = 7
}

resource "aws_lambda_function" "certificate_renewal" {
  function_name    = "count-certificate-renewal"
  role             = aws_iam_role.certificate_renewal.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = "${path.module}/certificate_renewal.zip"
  source_code_hash = filebase64sha256("${path.module}/certificate_renewal.zip")
  timeout          = 30
  environment { variables = {
    CERTIFICATE_ARN       = aws_acm_certificate.count.arn
    TLS_BUNDLE_SECRET_ARN = aws_secretsmanager_secret.tls_bundle.arn
    CLUSTER_NAME          = aws_ecs_cluster.count.name
    SERVICE_NAME          = aws_ecs_service.count.name
    HTTPS_ENABLED         = tostring(var.enable_https)
  } }
  depends_on = [aws_iam_role_policy.certificate_renewal]
}

resource "aws_cloudwatch_event_rule" "certificate_renewal" {
  name = "count-certificate-available"
  event_pattern = jsonencode({
    source    = ["aws.acm"], "detail-type" = ["ACM Certificate Available"],
    resources = [aws_acm_certificate.count.arn], detail = { Action = ["RENEWAL"] }
  })
}

resource "aws_cloudwatch_event_target" "certificate_renewal" {
  rule = aws_cloudwatch_event_rule.certificate_renewal.name
  arn  = aws_lambda_function.certificate_renewal.arn
}

resource "aws_cloudwatch_event_rule" "certificate_expiry_check" {
  name                = "count-certificate-expiry-check"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "certificate_expiry_check" {
  rule  = aws_cloudwatch_event_rule.certificate_expiry_check.name
  arn   = aws_lambda_function.certificate_renewal.arn
  input = jsonencode({ check_expiry = true })
}

resource "aws_lambda_permission" "certificate_expiry_check" {
  statement_id  = "AllowCountCertificateExpiryCheck"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.certificate_renewal.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.certificate_expiry_check.arn
}

resource "aws_lambda_permission" "certificate_renewal" {
  statement_id  = "AllowCountCertificateEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.certificate_renewal.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.certificate_renewal.arn
}

resource "aws_cloudwatch_metric_alarm" "dns_errors" {
  alarm_name          = "count-dns-reconcile-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.dns_reconcile.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "certificate_errors" {
  alarm_name          = "count-certificate-renewal-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.certificate_renewal.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}
