"""
Image processor Lambda
Triggered by: SQS image queue
Writes image metadata to DynamoDB.
Returns batchItemFailures so only failed messages retry.
"""

import json
import boto3
import os
import urllib.parse
import hashlib
from datetime import datetime, timezone

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])


def lambda_handler(event, context):
    batch_item_failures = []

    for record in event.get("Records", []):
        message_id = record.get("messageId")
        try:
            process_record(record)
        except Exception as e:
            print(f"FAILED messageId={message_id} error={str(e)}")
            batch_item_failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": batch_item_failures}


def process_record(record):
    body = json.loads(record["body"])
    detail = body.get("detail", body)

    bucket = detail["bucket"]["name"]
    key = urllib.parse.unquote_plus(detail["object"]["key"])
    size = detail["object"].get("size", 0)

    print(f"Processing: s3://{bucket}/{key}")

    # Read metadata from S3 object
    head = s3.head_object(Bucket=bucket, Key=key)

    etag = head.get("ETag", "").strip('"')
    ext = key.rsplit(".", 1)[-1].lower() if "." in key else "unknown"

    # Use ETag if available, otherwise fallback to hash of key
    file_id = etag if etag else hashlib.md5(key.encode("utf-8")).hexdigest()

    item = {
        "file_id": file_id,
        "s3_key": key,
        "bucket": bucket,
        "file_type": ext,
        "category": "image",
        "size_bytes": int(size),
        "content_type": head.get("ContentType", ""),
        "etag": etag,
        "upload_time": datetime.now(timezone.utc).isoformat(),
        "last_modified": head["LastModified"].isoformat(),
        "processing_status": "PROCESSED",
    }

    table.put_item(Item=item)
    print(f"Stored file_id={file_id} for key={key}")