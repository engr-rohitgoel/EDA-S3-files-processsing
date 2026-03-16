variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project prefix"
  type        = string
  default     = "eda"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "alert_email" {
  description = "Email address for SNS upload alerts"
  type        = string
}

variable "s3_bucket_name" {
  description = "Optional custom S3 bucket name. Leave empty to auto-generate."
  type        = string
  default     = ""
}

variable "text_lambda_timeout" {
  description = "Timeout for text lambda in seconds"
  type        = number
  default     = 300
}

variable "image_lambda_timeout" {
  description = "Timeout for image lambda in seconds"
  type        = number
  default     = 300
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}