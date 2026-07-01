terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region     = "eu-west-1"
  access_key = "test"
  secret_key = "test"

  # Required for Floci / any local AWS emulator
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  # Point all services at Floci
  endpoints {
    s3             = "http://localhost:4566"
    sqs            = "http://localhost:4566"
    dynamodb       = "http://localhost:4566"
    sns            = "http://localhost:4566"
    lambda         = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    ssm            = "http://localhost:4566"
    kms            = "http://localhost:4566"
    cloudwatch     = "http://localhost:4566"
    logs           = "http://localhost:4566"
    events         = "http://localhost:4566"
    stepfunctions  = "http://localhost:4566"
  }
}

# ── S3 ────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "app_data" {
  bucket = "tf-demo-app-data"
}

resource "aws_s3_bucket_versioning" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {} # applies to the whole bucket — required since provider v4+ to disambiguate scope
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ── SQS ───────────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  name = "tf-demo-dlq"
}

resource "aws_sqs_queue" "orders" {
  name                       = "tf-demo-orders"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "orders" {
  name         = "tf-demo-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }

  attribute {
    name = "customerId"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  global_secondary_index {
    name            = "customer-index"
    hash_key        = "customerId"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  tags = {
    Environment = "floci-demo"
    ManagedBy   = "terraform"
  }
}

# ── SNS ───────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "order_events" {
  name = "tf-demo-order-events"
}

resource "aws_sns_topic_subscription" "orders_sqs" {
  topic_arn = aws_sns_topic.order_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.orders.arn
}

# ── SSM ───────────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "app_config" {
  name  = "/tf-demo/app/config"
  type  = "String"
  value = jsonencode({
    featureFlags = {
      newCheckout  = true
      betaSearch   = false
    }
    rateLimits = {
      ordersPerMinute = 100
    }
  })
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/tf-demo/db/password"
  type  = "SecureString"
  value = "super-secret-floci-pass"
}

# ── Secrets Manager ───────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "api_credentials" {
  name = "tf-demo/api/credentials"
}

resource "aws_secretsmanager_secret_version" "api_credentials" {
  secret_id = aws_secretsmanager_secret.api_credentials.id
  secret_string = jsonencode({
    apiKey    = "sk-tf-demo-key"
    endpoint  = "https://api.internal"
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "s3_bucket" {
  value = aws_s3_bucket.app_data.bucket
}

output "orders_queue_url" {
  value = aws_sqs_queue.orders.url
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "dynamodb_table" {
  value = aws_dynamodb_table.orders.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.order_events.arn
}
