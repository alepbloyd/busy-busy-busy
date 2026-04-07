terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.2"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}

variable "site_prefix" {
  description = "Prefix for naming of resources"
  default     = "busy-busy-busy"
  type        = string
}

provider "archive" {}

variable "gtfs_bucket_name" {
  description = "Optional: S3 bucket name for GTFS files (must be globally unique). If empty, a name is generated." 
  type = string
  default = ""
}

variable "wmata_api_key" {
  description = "WMATA API key for Bus Route and Stop Methods access"
  type        = string
  default     = ""
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region for Lambda and resources"
  type        = string
  default     = "us-east-1"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_s3_bucket" "gtfs_bucket" {
  bucket = length(var.gtfs_bucket_name) > 0 ? var.gtfs_bucket_name : "${var.site_prefix}-gtfs"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.site_prefix}_gtfs_bucket"
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "${var.site_prefix}_gtfs_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.site_prefix}_gtfs_lambda_policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow",
        Action = ["s3:PutObject", "s3:PutObjectAcl"],
        Resource = ["${aws_s3_bucket.gtfs_bucket.arn}/*"]
      }
    ]
  })
}

resource "aws_lambda_function" "daily_gtfs_static" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.site_prefix}_daily_gtfs_static"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.daily_gtfs_static_handler"
  runtime          = "python3.10"
  timeout          = 600
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      BUCKET           = aws_s3_bucket.gtfs_bucket.bucket
      WMATA_API_KEY    = var.wmata_api_key
      WMATA_STATIC_URL = "https://api.wmata.com/gtfs/bus-gtfs-static.zip"
    }
  }

  depends_on = [aws_iam_role_policy.lambda_policy]
}

resource "aws_lambda_function" "trip_updates" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.site_prefix}_trip_updates"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.trip_updates_handler"
  runtime          = "python3.10"
  timeout          = 120
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      BUCKET                     = aws_s3_bucket.gtfs_bucket.bucket
      WMATA_API_KEY              = var.wmata_api_key
      WMATA_TRIP_UPDATES_URL     = "https://api.wmata.com/gtfs/bus-gtfsrt-tripupdates.pb"
      WMATA_VEHICLE_POSITIONS_URL = "https://api.wmata.com/gtfs/bus-gtfsrt-vehiclepositions.pb"
      WMATA_ALERTS_URL           = "https://api.wmata.com/gtfs/bus-gtfsrt-alerts.pb"
      WMATA_BUS_INCIDENTS_URL    = "http://api.wmata.com/Incidents.svc/json/BusIncidents"
      GTFS_REALTIME_INTERVAL_SECONDS = "20"
      GTFS_REALTIME_SWEEPS_PER_INVOCATION = "3"
    }
  }

  depends_on = [aws_iam_role_policy.lambda_policy]
}

resource "aws_cloudwatch_event_rule" "daily_static_schedule" {
  name                = "${var.site_prefix}_daily_static_schedule"
  description         = "Schedule to invoke WMATA GTFS static collector once per day"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "daily_static_target" {
  rule      = aws_cloudwatch_event_rule.daily_static_schedule.name
  target_id = "daily_static"
  arn       = aws_lambda_function.daily_gtfs_static.arn
}

resource "aws_cloudwatch_event_rule" "trip_updates_schedule" {
  name                = "${var.site_prefix}_trip_updates_schedule"
  description         = "Schedule to invoke WMATA GTFS realtime collector every minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "trip_updates_target" {
  rule      = aws_cloudwatch_event_rule.trip_updates_schedule.name
  target_id = "trip_updates"
  arn       = aws_lambda_function.trip_updates.arn
}

resource "aws_lambda_permission" "allow_eventbridge_daily" {
  statement_id  = "AllowExecutionFromEventBridgeDaily"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.daily_gtfs_static.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_static_schedule.arn
}

resource "aws_lambda_permission" "allow_eventbridge_trip_updates" {
  statement_id  = "AllowExecutionFromEventBridgeTripUpdates"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trip_updates.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.trip_updates_schedule.arn
}

output "gtfs_bucket" {
  value = aws_s3_bucket.gtfs_bucket.bucket
}

