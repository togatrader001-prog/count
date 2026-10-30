terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_cloudwatch_log_group" "count" {
  name              = "/ecs/count"
  retention_in_days = 7
}

resource "aws_iam_role" "execution" {
  name = "count-ecs-execution"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_security_group" "count" {
  name        = "count-ecs"
  description = "Allow access to Count from the configured client IP"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    from_port   = var.enable_https ? 443 : 3000
    to_port     = var.enable_https ? 443 : 3000
    protocol    = "tcp"
    cidr_blocks = length(var.https_allowed_cidrs) > 0 && var.enable_https ? var.https_allowed_cidrs : [var.allowed_cidr]
  }
  dynamic "ingress" {
    for_each = var.enable_https && var.keep_legacy_http ? [1] : []
    content {
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

variable "allowed_cidr" {
  description = "Client IPv4 CIDR permitted to access the API, for example your public IP followed by /32."
  type        = string
}

variable "image_uri" {
  description = "The existing Count ECR image URI including its commit tag."
  type        = string
}

resource "aws_ecs_cluster" "count" {
  name = "count"
}

resource "aws_ecs_task_definition" "count" {
  family                   = "count"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  container_definitions = jsonencode([merge({
    name         = "count"
    image        = var.image_uri
    essential    = true
    portMappings = [{ containerPort = var.enable_https ? 443 : 3000, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.count.name
        awslogs-region        = "us-east-2"
        awslogs-stream-prefix = "count"
      }
    }
    }, jsondecode(var.enable_https ? jsonencode({
      environment = [{ name = "PORT", value = "443" }]
      secrets     = [{ name = "COUNT_TLS_BUNDLE", valueFrom = aws_secretsmanager_secret.tls_bundle.arn }]
      healthCheck = {
        command     = ["CMD-SHELL", "node -e \"require('https').get({hostname:'127.0.0.1',port:443,path:'/health',rejectUnauthorized:false},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
  }) : "{}"))])
}

resource "aws_ecs_service" "count" {
  name            = "count"
  cluster         = aws_ecs_cluster.count.id
  task_definition = aws_ecs_task_definition.count.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.count.id]
    assign_public_ip = true
  }
  depends_on = [aws_iam_role_policy_attachment.execution]
}
