"""
Text / CSV processor Lambda
Triggered by: SQS text queue
Reads file from S3, extracts metadata, writes to DynamoDB.
Returns batchItemFailures so only failed messages retry (not the whole batch).
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

    for record in event["Records"]:
        message_id = record["messageId"]
        try:
            process_record(record)
        except Exception as e:
            print(f"FAILED messageId={message_id} error={e}")
            batch_item_failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": batch_item_failures}


def process_record(record):
    body = json.loads(record["body"])
    detail = body.get("detail", body)

    bucket = detail["bucket"]["name"]
    key = urllib.parse.unquote_plus(detail["object"]["key"])
    size = detail["object"].get("size", 0)

    print(f"Processing: s3://{bucket}/{key}")

    response = s3.get_object(Bucket=bucket, Key=key)
    raw = response["Body"].read(10240)  # first 10 KB for metadata only

    try:
        content = raw.decode("utf-8")
        encoding = "utf-8"
    except UnicodeDecodeError:
        content = raw.decode("latin-1")
        encoding = "latin-1"

    ext = key.rsplit(".", 1)[-1].lower() if "." in key else "unknown"
    etag = response.get("ETag", "").strip('"')
    file_id = etag or hashlib.md5(key.encode()).hexdigest()

    item = {
        "file_id": file_id,
        "s3_key": key,
        "bucket": bucket,
        "file_type": ext,
        "category": "text",
        "size_bytes": size,
        "encoding": encoding,
        "content_type": response.get("ContentType", ""),
        "upload_time": datetime.now(timezone.utc).isoformat(),
        "last_modified": response["LastModified"].isoformat(),
        "processing_status": "PROCESSED",
        **extract_metadata(content, ext),
    }

    table.put_item(Item=item)
    print(f"Stored file_id={file_id}")


def extract_metadata(content: str, ext: str) -> dict:
    lines = content.splitlines()
    meta = {
        "line_count": len(lines),
        "word_count": len(content.split()),
        "char_count": len(content),
    }
    if ext == "csv" and lines:
        headers = [h.strip().strip('"') for h in lines[0].split(",")]
        meta["csv_headers"] = headers
        meta["csv_column_count"] = len(headers)
        meta["csv_row_count"] = max(0, len(lines) - 1)
    return meta
