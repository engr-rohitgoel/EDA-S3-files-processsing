terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  bucket_name = var.s3_bucket_name != "" ? var.s3_bucket_name : "${local.name_prefix}-uploads-${data.aws_caller_identity.current.account_id}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    },
    var.tags
  )
}

############################################
# S3 BUCKET
############################################

resource "aws_s3_bucket" "uploads" {
  bucket = local.bucket_name

  tags = merge(local.common_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enables EventBridge delivery for this bucket
resource "aws_s3_bucket_notification" "uploads" {
  bucket      = aws_s3_bucket.uploads.id
  eventbridge = true
}

############################################
# SNS
############################################

resource "aws_sns_topic" "upload_alerts" {
  name = "${local.name_prefix}-upload-alerts"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "upload_alerts_email" {
  topic_arn = aws_sns_topic.upload_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowSNSDefaultPolicy"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "sns:Publish",
      "sns:RemovePermission",
      "sns:SetTopicAttributes",
      "sns:DeleteTopic",
      "sns:ListSubscriptionsByTopic",
      "sns:GetTopicAttributes",
      "sns:AddPermission",
      "sns:Subscribe"
    ]

    resources = [aws_sns_topic.upload_alerts.arn]
  }

  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.upload_alerts.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.all_uploads.arn]
    }
  }
}

resource "aws_sns_topic_policy" "upload_alerts" {
  arn    = aws_sns_topic.upload_alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

############################################
# SQS
############################################

resource "aws_sqs_queue" "text_queue" {
  name                      = "${local.name_prefix}-text-queue"
  visibility_timeout_seconds = var.text_lambda_timeout
  message_retention_seconds  = 86400

  tags = local.common_tags
}

resource "aws_sqs_queue" "image_queue" {
  name                      = "${local.name_prefix}-image-queue"
  visibility_timeout_seconds = var.image_lambda_timeout
  message_retention_seconds  = 86400

  tags = local.common_tags
}

# Allow EventBridge rule to send to text queue
data "aws_iam_policy_document" "text_queue_policy" {
  statement {
    sid    = "AllowEventBridgeSendText"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.text_queue.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.text_files.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "text_queue_policy" {
  queue_url = aws_sqs_queue.text_queue.id
  policy    = data.aws_iam_policy_document.text_queue_policy.json
}

# Allow EventBridge rule to send to image queue
data "aws_iam_policy_document" "image_queue_policy" {
  statement {
    sid    = "AllowEventBridgeSendImage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.image_queue.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.image_files.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "image_queue_policy" {
  queue_url = aws_sqs_queue.image_queue.id
  policy    = data.aws_iam_policy_document.image_queue_policy.json
}

############################################
# DYNAMODB
############################################

resource "aws_dynamodb_table" "file_metadata" {
  name         = "${local.name_prefix}-file-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "file_id"

  attribute {
    name = "file_id"
    type = "S"
  }

  tags = local.common_tags
}

############################################
# IAM - TEXT LAMBDA ROLE
############################################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "text_lambda_role" {
  name               = "${local.name_prefix}-text-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "text_lambda_basic" {
  role       = aws_iam_role.text_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "text_lambda_inline" {
  statement {
    sid    = "ConsumeTextQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility"
    ]
    resources = [aws_sqs_queue.text_queue.arn]
  }

  statement {
    sid    = "ReadUploadsBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]
  }

  statement {
    sid    = "WriteMetadata"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem"
    ]
    resources = [aws_dynamodb_table.file_metadata.arn]
  }
}

resource "aws_iam_role_policy" "text_lambda_inline" {
  name   = "${local.name_prefix}-text-inline-policy"
  role   = aws_iam_role.text_lambda_role.id
  policy = data.aws_iam_policy_document.text_lambda_inline.json
}

############################################
# IAM - IMAGE LAMBDA ROLE
############################################

resource "aws_iam_role" "image_lambda_role" {
  name               = "${local.name_prefix}-image-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "image_lambda_basic" {
  role       = aws_iam_role.image_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "image_lambda_inline" {
  statement {
    sid    = "ConsumeImageQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility"
    ]
    resources = [aws_sqs_queue.image_queue.arn]
  }

  statement {
    sid    = "ReadUploadsBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]
  }

  statement {
    sid    = "WriteMetadata"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem"
    ]
    resources = [aws_dynamodb_table.file_metadata.arn]
  }
}

resource "aws_iam_role_policy" "image_lambda_inline" {
  name   = "${local.name_prefix}-image-inline-policy"
  role   = aws_iam_role.image_lambda_role.id
  policy = data.aws_iam_policy_document.image_lambda_inline.json
}

############################################
# LAMBDA PACKAGING
############################################

data "archive_file" "text_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/text_processor/handler.py"
  output_path = "${path.module}/lambda/text_processor.zip"
}

data "archive_file" "image_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/image_processor/handler.py"
  output_path = "${path.module}/lambda/image_processor.zip"
}

############################################
# LAMBDAS
############################################

resource "aws_lambda_function" "text_processor" {
  function_name = "${local.name_prefix}-text-processor"
  role          = aws_iam_role.text_lambda_role.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"

  filename         = data.archive_file.text_lambda_zip.output_path
  source_code_hash = data.archive_file.text_lambda_zip.output_base64sha256

  timeout     = var.text_lambda_timeout
  memory_size = 256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.file_metadata.name
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "image_processor" {
  function_name = "${local.name_prefix}-image-processor"
  role          = aws_iam_role.image_lambda_role.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"

  filename         = data.archive_file.image_lambda_zip.output_path
  source_code_hash = data.archive_file.image_lambda_zip.output_path != "" ? data.archive_file.image_lambda_zip.output_base64sha256 : null

  timeout     = var.image_lambda_timeout
  memory_size = 512

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.file_metadata.name
    }
  }

  tags = local.common_tags
}

############################################
# LAMBDA <-> SQS EVENT SOURCE MAPPINGS
############################################

resource "aws_lambda_event_source_mapping" "text_queue_mapping" {
  event_source_arn                   = aws_sqs_queue.text_queue.arn
  function_name                      = aws_lambda_function.text_processor.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 10
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [
    aws_iam_role_policy.text_lambda_inline,
    aws_iam_role_policy_attachment.text_lambda_basic
  ]
}

resource "aws_lambda_event_source_mapping" "image_queue_mapping" {
  event_source_arn                   = aws_sqs_queue.image_queue.arn
  function_name                      = aws_lambda_function.image_processor.arn
  batch_size                         = 3
  maximum_batching_window_in_seconds = 10
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [
    aws_iam_role_policy.image_lambda_inline,
    aws_iam_role_policy_attachment.image_lambda_basic
  ]
}

############################################
# EVENTBRIDGE RULES
############################################

resource "aws_cloudwatch_event_rule" "text_files" {
  name        = "${local.name_prefix}-text-file-rule"
  description = "Route .txt and .csv uploads from S3 to text SQS queue"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.uploads.bucket]
      }
      object = {
        key = [
          { suffix = ".txt" },
          { suffix = ".csv" },
          { suffix = ".TXT" },
          { suffix = ".CSV" }
        ]
      }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "text_queue_target" {
  rule      = aws_cloudwatch_event_rule.text_files.name
  target_id = "TextQueueTarget"
  arn       = aws_sqs_queue.text_queue.arn
}

resource "aws_cloudwatch_event_rule" "image_files" {
  name        = "${local.name_prefix}-image-file-rule"
  description = "Route image uploads from S3 to image SQS queue"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.uploads.bucket]
      }
      object = {
        key = [
          { suffix = ".png" },
          { suffix = ".jpg" },
          { suffix = ".jpeg" },
          { suffix = ".PNG" },
          { suffix = ".JPG" },
          { suffix = ".JPEG" }
        ]
      }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "image_queue_target" {
  rule      = aws_cloudwatch_event_rule.image_files.name
  target_id = "ImageQueueTarget"
  arn       = aws_sqs_queue.image_queue.arn
}

resource "aws_cloudwatch_event_rule" "all_uploads" {
  name        = "${local.name_prefix}-all-uploads-rule"
  description = "Send SNS notification for every upload"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.uploads.bucket]
      }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.all_uploads.name
  target_id = "UploadAlertsSNSTarget"
  arn       = aws_sns_topic.upload_alerts.arn

  input_transformer {
    input_paths = {
      bucket    = "$.detail.bucket.name"
      key       = "$.detail.object.key"
      size      = "$.detail.object.size"
      eventtime = "$.time"
    }

    input_template = "\"New file uploaded\\nBucket: <bucket>\\nFile: <key>\\nSize: <size> bytes\\nTime: <eventtime>\""
  }
}