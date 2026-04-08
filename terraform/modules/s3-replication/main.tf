###############################################################
# S3 Cross-Region Replication (CRR) with Replication Time Control
# Source: us-east-1 → Destination: us-west-2 + eu-west-1
###############################################################

variable "bucket_prefix" {
  description = "Prefix for S3 bucket names"
  type        = string
  default     = "myapp-prod"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "replication_lag_alarm_sns" {
  description = "SNS ARN for replication lag alerts"
  type        = string
}

##################################################
# Source Bucket — us-east-1 (Primary)
##################################################

resource "aws_s3_bucket" "source" {
  provider = aws.primary
  bucket   = "${var.bucket_prefix}-primary-us-east-1"

  tags = {
    Name        = "${var.bucket_prefix}-primary"
    Environment = var.environment
    Region      = "us-east-1"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "source" {
  provider = aws.primary
  bucket   = aws_s3_bucket.source.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  provider = aws.primary
  bucket   = aws_s3_bucket.source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  provider = aws.primary
  bucket   = aws_s3_bucket.source.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "source" {
  provider = aws.primary
  bucket   = aws_s3_bucket.source.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

##################################################
# Destination Bucket — us-west-2 (DR Region 1)
##################################################

resource "aws_s3_bucket" "destination_dr1" {
  provider = aws.dr_region_1
  bucket   = "${var.bucket_prefix}-dr-us-west-2"

  tags = {
    Name        = "${var.bucket_prefix}-dr1"
    Environment = var.environment
    Region      = "us-west-2"
    Role        = "dr-replica"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "destination_dr1" {
  provider = aws.dr_region_1
  bucket   = aws_s3_bucket.destination_dr1.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "destination_dr1" {
  provider = aws.dr_region_1
  bucket   = aws_s3_bucket.destination_dr1.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "destination_dr1" {
  provider = aws.dr_region_1
  bucket   = aws_s3_bucket.destination_dr1.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

##################################################
# IAM Role for Replication
##################################################

resource "aws_iam_role" "s3_replication" {
  name = "s3-cross-region-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "s3.amazonaws.com"
      }
    }]
  })

  tags = {
    ManagedBy = "terraform"
  }
}

resource "aws_iam_policy" "s3_replication" {
  name = "s3-cross-region-replication-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = [aws_s3_bucket.source.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = ["${aws_s3_bucket.source.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = [
          "${aws_s3_bucket.destination_dr1.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = ["*"]
        Condition = {
          StringLike = {
            "kms:ViaService" = "s3.us-east-1.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey"
        ]
        Resource = ["*"]
        Condition = {
          StringLike = {
            "kms:ViaService" = "s3.us-west-2.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_replication" {
  role       = aws_iam_role.s3_replication.name
  policy_arn = aws_iam_policy.s3_replication.arn
}

##################################################
# Replication Configuration with RTC
##################################################

resource "aws_s3_bucket_replication_configuration" "source_to_dr1" {
  provider = aws.primary

  role   = aws_iam_role.s3_replication.arn
  bucket = aws_s3_bucket.source.id

  rule {
    id     = "replicate-all-to-us-west-2"
    status = "Enabled"

    filter {
      prefix = ""
    }

    destination {
      bucket        = aws_s3_bucket.destination_dr1.arn
      storage_class = "STANDARD"

      # Replication Time Control — 99.99% objects replicated in 15 min
      replication_time {
        status = "Enabled"
        time {
          minutes = 15
        }
      }

      # Emit replication metrics for monitoring
      metrics {
        status = "Enabled"
        event_threshold {
          minutes = 15
        }
      }
    }

    delete_marker_replication {
      status = "Enabled"
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.source,
    aws_s3_bucket_versioning.destination_dr1
  ]
}

##################################################
# CloudWatch Alarms for Replication Lag
##################################################

resource "aws_cloudwatch_metric_alarm" "replication_lag" {
  provider = aws.primary

  alarm_name          = "s3-replication-lag-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicationLatency"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900 # 15 minutes in seconds
  alarm_description   = "S3 replication latency exceeded 15 minutes — investigate replication pipeline"
  alarm_actions       = [var.replication_lag_alarm_sns]
  treat_missing_data  = "notBreaching"

  dimensions = {
    SourceBucket      = aws_s3_bucket.source.id
    DestinationBucket = aws_s3_bucket.destination_dr1.id
    RuleId            = "replicate-all-to-us-west-2"
  }
}

resource "aws_cloudwatch_metric_alarm" "replication_failed_bytes" {
  provider = aws.primary

  alarm_name          = "s3-replication-failed-bytes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BytesPendingReplication"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Sum"
  threshold           = 1073741824 # 1 GB pending = alert
  alarm_description   = "Over 1 GB pending S3 replication — possible replication backlog"
  alarm_actions       = [var.replication_lag_alarm_sns]
  treat_missing_data  = "notBreaching"

  dimensions = {
    SourceBucket      = aws_s3_bucket.source.id
    DestinationBucket = aws_s3_bucket.destination_dr1.id
    RuleId            = "replicate-all-to-us-west-2"
  }
}

##################################################
# Outputs
##################################################

output "source_bucket_name" {
  value = aws_s3_bucket.source.id
}

output "source_bucket_arn" {
  value = aws_s3_bucket.source.arn
}

output "dr1_bucket_name" {
  value = aws_s3_bucket.destination_dr1.id
}

output "dr1_bucket_arn" {
  value = aws_s3_bucket.destination_dr1.arn
}

output "replication_role_arn" {
  value = aws_iam_role.s3_replication.arn
}
