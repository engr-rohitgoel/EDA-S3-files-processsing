output "s3_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "sns_topic_arn" {
  value = aws_sns_topic.upload_alerts.arn
}

output "text_queue_url" {
  value = aws_sqs_queue.text_queue.id
}

output "text_queue_arn" {
  value = aws_sqs_queue.text_queue.arn
}

output "image_queue_url" {
  value = aws_sqs_queue.image_queue.id
}

output "image_queue_arn" {
  value = aws_sqs_queue.image_queue.arn
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.file_metadata.name
}

output "text_lambda_name" {
  value = aws_lambda_function.text_processor.function_name
}

output "image_lambda_name" {
  value = aws_lambda_function.image_processor.function_name
}