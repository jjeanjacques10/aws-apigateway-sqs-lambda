terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

## Configure the AWS Provider
provider "aws" {
  region = var.region
}

resource "aws_sqs_queue" "queue" {
  name                      = "coffee-request-queue"
  delay_seconds             = 0      // how long to delay delivery of records
  max_message_size          = 262144 // = 256KiB, which is the limit set by AWS
  message_retention_seconds = 86400  // = 1 day in seconds
  receive_wait_time_seconds = 10     // how long to wait for a record to stream in when ReceiveMessage is called
}

## Role API Gateway
resource "aws_iam_role" "gtw_role" {
  name = "coffee-api-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

## Policy API Gateway
resource "aws_iam_policy" "api" {
  name = "coffee-api-policy"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:FilterLogEvents"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "sqs:GetQueueUrl",
          "sqs:ChangeMessageVisibility",
          "sqs:ListDeadLetterSourceQueues",
          "sqs:SendMessageBatch",
          "sqs:PurgeQueue",
          "sqs:ReceiveMessage",
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
          "sqs:CreateQueue",
          "sqs:ListQueueTags",
          "sqs:ChangeMessageVisibilityBatch",
          "sqs:SetQueueAttributes"
        ],
        "Resource": "${aws_sqs_queue.queue.arn}"
      },
      {
        "Effect": "Allow",
        "Action": "sqs:ListQueues",
        "Resource": "*"
      }      
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "api" {
  role       = aws_iam_role.gtw_role.name
  policy_arn = aws_iam_policy.api.arn
}

## API Gateway
resource "aws_api_gateway_rest_api" "api" {
  name        = "coffee-sqs-api"
  description = "POST records to SQS queue"
}

resource "aws_api_gateway_request_validator" "api" {
  rest_api_id           = aws_api_gateway_rest_api.api.id
  name                  = "payload-validator"
  validate_request_body = true
}

resource "aws_api_gateway_model" "api" {
  rest_api_id  = aws_api_gateway_rest_api.api.id
  name         = "PayloadValidator"
  description  = "validate the json body content conforms to the below spec"
  content_type = "application/json"

  schema = <<EOF
{
  "$schema": "http://json-schema.org/draft-04/schema#",
  "type": "object",
  "required": [ "name", "order"],
  "properties": {
    "name": { "type": "string" },
    "order": {
      "type": "object",
      "required": ["value", "item"],
      "properties": {
        "value": { "type": "number" },
        "item": { "type": "string" }
      }
    }
  }
}
EOF
}

resource "aws_api_gateway_method" "api" {
  rest_api_id      = aws_api_gateway_rest_api.api.id
  resource_id      = aws_api_gateway_rest_api.api.root_resource_id
  api_key_required = false
  http_method      = "POST"
  authorization    = "NONE"
  #request_validator_id = "${aws_api_gateway_request_validator.api.id}"

  request_models = {
    "application/json" = "${aws_api_gateway_model.api.name}"
  }
}

## Queue Integration
resource "aws_api_gateway_integration" "api" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_rest_api.api.root_resource_id
  http_method             = "POST"
  type                    = "AWS"
  integration_http_method = "POST"
  passthrough_behavior    = "NEVER"
  credentials             = aws_iam_role.gtw_role.arn
  uri                     = "arn:aws:apigateway:${var.region}:sqs:path/${aws_sqs_queue.queue.name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$input.body"
  }
}

## API Response
resource "aws_api_gateway_integration_response" "integration_response_200" {
  rest_api_id       = aws_api_gateway_rest_api.api.id
  resource_id       = aws_api_gateway_rest_api.api.root_resource_id
  http_method       = aws_api_gateway_method.api.http_method
  status_code       = aws_api_gateway_method_response.method_response_200.status_code
  selection_pattern = "^2[0-9][0-9]" // regex pattern for any 200 message that comes back from SQS

  response_templates = {
    "application/json" = "{\"message\": \"coffee order processing\"}"
  }

  depends_on = [aws_api_gateway_integration.api]
}

resource "aws_api_gateway_method_response" "method_response_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_rest_api.api.root_resource_id
  http_method = aws_api_gateway_method.api.http_method
  status_code = 200

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "coffee"

  depends_on = [
    aws_api_gateway_integration.api,
  ]
}


## Permissions Lambda
# Lambda function policy
resource "aws_iam_policy" "lambda_policy" {
  name        = "lambda-policy"
  description = "lambda-policy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Effect": "Allow",
      "Resource": "${aws_sqs_queue.queue.arn}"
    },
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

# Lambda function role
resource "aws_iam_role" "lambda_role" {
  name = "lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_lambda_iam_policy_basic_execution" {
  role       = aws_iam_role.lambda_role.id
  policy_arn = aws_iam_policy.lambda_policy.arn
}

data "archive_file" "function_archive" {
  type        = "zip"
  source_file = local.binary_path
  output_path = local.archive_path
}

## Lambda Function
resource "aws_lambda_function" "function" {
  function_name = local.function_name
  description   = "Lambda function to get coffee requests"
  role          = aws_iam_role.lambda_role.arn
  handler       = local.function_name
  memory_size   = 128

  filename         = local.archive_path
  source_code_hash = data.archive_file.function_archive.output_base64sha256

  runtime = "go1.x"
}

# Event source from SQS
resource "aws_lambda_event_source_mapping" "event_source_mapping" {
  event_source_arn = aws_sqs_queue.queue.arn
  enabled          = true
  function_name    = aws_lambda_function.function.arn
  batch_size       = 10
}