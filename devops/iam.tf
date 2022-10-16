#
# lambda assume role policy
#

# trust relationships
data "aws_iam_policy_document" "fastapi_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fastapi_role" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.fastapi_assume_role_policy.json
}


resource "aws_cloudwatch_log_group" "fastapi_logging_group" {
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "fastapi_logging_role_policy" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
    effect = "Allow"
  }
}

resource "aws_iam_policy" "fastapi_logging" {
  name        = "fastapi_logging"
  path        = "/"
  description = "IAM policy for logging from a lambda"

  policy = data.aws_iam_policy_document.fastapi_logging_role_policy.json
}

resource "aws_iam_role_policy_attachment" "fastapi_logs" {
  role       = aws_iam_role.fastapi_role.name
  policy_arn = aws_iam_policy.fastapi_logging.arn
}
