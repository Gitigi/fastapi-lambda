terraform {
  required_version = ">= 1.2.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>4.26"
    }
  }
}

provider "aws" {
  region     = "eu-west-1"
  access_key = var.access_key
  secret_key = var.secret_key
}

resource "null_resource" "install_dependencies" {
  provisioner "local-exec" {
    command = "pip install -r ../requirements.txt -t ../requirements/python"
  }

  triggers = {
    dependencies_versions = filemd5("../requirements.txt")
  }
}

data "archive_file" "requirements" {
  depends_on = [null_resource.install_dependencies]
  type        = "zip"
  source_dir = "../requirements"
  output_path = "../requirements.zip"
}

data "archive_file" "zip" {
  type        = "zip"
  source_file = "../main.py"
  output_path = "../main.zip"
}

resource "aws_lambda_function" "fastapi" {
  filename         = data.archive_file.zip.output_path
  source_code_hash = data.archive_file.zip.output_base64sha256

  function_name = var.project_name
  role          = aws_iam_role.fastapi_role.arn
  handler       = "main.handler"
  runtime       = "python3.9"
  layers = [aws_lambda_layer_version.fastapiRequirements.arn]
  # timeout       = 10

  depends_on = [
    aws_iam_role_policy_attachment.fastapi_logs,
    aws_cloudwatch_log_group.fastapi_logging_group,
  ]
}

resource "aws_lambda_layer_version" "fastapiRequirements" {
  filename         = data.archive_file.requirements.output_path
  source_code_hash = data.archive_file.requirements.output_base64sha256
  layer_name = "fastapiRequirements"

  compatible_runtimes = ["python3.9"]
}

resource "aws_lambda_permission" "lambda_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fastapi.function_name
  principal     = "apigateway.amazonaws.com"

  # The "/*/*" portion grants access from any method on any resource
  # within the API Gateway REST API.
  source_arn = "${aws_api_gateway_rest_api.api_gateway.execution_arn}/*/*"
}

resource "aws_api_gateway_rest_api" "api_gateway" {
  name        = var.project_name
  description = "created with terraform"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.api_gateway.id
  parent_id   = aws_api_gateway_rest_api.api_gateway.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.api_gateway.id
  resource_id   = aws_api_gateway_rest_api.api_gateway.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.api_gateway.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = aws_api_gateway_rest_api.api_gateway.id
  resource_id = aws_api_gateway_method.root.resource_id
  http_method = aws_api_gateway_method.root.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.fastapi.invoke_arn
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.api_gateway.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.fastapi.invoke_arn
}


resource "aws_api_gateway_deployment" "fastapi_root" {
  depends_on = [
    aws_api_gateway_integration.lambda_root
  ]
  
  rest_api_id = aws_api_gateway_rest_api.api_gateway.id
  
  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.
    redeployment = sha1(jsonencode([
      aws_api_gateway_rest_api.api_gateway.root_resource_id,
      aws_api_gateway_method.root.id,
      aws_api_gateway_integration.lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_deployment" "fastapi" {
  depends_on = [
    aws_api_gateway_integration.lambda
  ]
  
  rest_api_id = aws_api_gateway_rest_api.api_gateway.id
  
  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_integration.lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}
  

resource "aws_api_gateway_stage" "fastapi" {
  deployment_id = aws_api_gateway_deployment.fastapi.id
  rest_api_id   = aws_api_gateway_rest_api.api_gateway.id
  stage_name    = "fastapi"
}

output "api_gateway_id" {
  value = aws_api_gateway_rest_api.api_gateway.id
}

output "fastapi" {
  value = "${aws_api_gateway_stage.fastapi.invoke_url}/"
}

