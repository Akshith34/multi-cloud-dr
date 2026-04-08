###############################################################
# Aurora Global Database — Cross-Region DR
# Primary: us-east-1 | Secondary: us-west-2
###############################################################

variable "cluster_identifier" {
  description = "Base identifier for Aurora clusters"
  type        = string
  default     = "prod-aurora-global"
}

variable "engine_version" {
  description = "Aurora MySQL compatible engine version"
  type        = string
  default     = "8.0.mysql_aurora.3.04.0"
}

variable "master_username" {
  description = "DB master username (stored in Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "master_password" {
  description = "DB master password (stored in Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "instance_class" {
  description = "Aurora instance class"
  type        = string
  default     = "db.r6g.xlarge"
}

variable "backup_retention_days" {
  description = "Automated backup retention period in days"
  type        = number
  default     = 7
}

variable "replication_lag_alarm_sns" {
  description = "SNS ARN for replication lag alarms"
  type        = string
}

##################################################
# Aurora Global Cluster
##################################################

resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "${var.cluster_identifier}-global"
  engine                    = "aurora-mysql"
  engine_version            = var.engine_version
  database_name             = "appdb"
  storage_encrypted         = true
  deletion_protection       = true
}

##################################################
# Primary Cluster — us-east-1
##################################################

resource "aws_rds_cluster" "primary" {
  provider = aws.primary

  cluster_identifier        = "${var.cluster_identifier}-primary"
  engine                    = "aurora-mysql"
  engine_version            = var.engine_version
  global_cluster_identifier = aws_rds_global_cluster.this.id

  master_username = var.master_username
  master_password = var.master_password

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"

  storage_encrypted   = true
  deletion_protection = true

  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]

  db_subnet_group_name   = aws_db_subnet_group.primary.name
  vpc_security_group_ids = [aws_security_group.aurora_primary.id]

  tags = {
    Name        = "${var.cluster_identifier}-primary"
    Role        = "primary-writer"
    Environment = "production"
    ManagedBy   = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_rds_cluster_instance" "primary" {
  count = 2

  identifier         = "${var.cluster_identifier}-primary-${count.index}"
  cluster_identifier = aws_rds_cluster.primary.id
  instance_class     = var.instance_class
  engine             = "aurora-mysql"
  engine_version     = var.engine_version

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 30
  monitoring_role_arn                   = aws_iam_role.rds_enhanced_monitoring.arn

  auto_minor_version_upgrade = true

  tags = {
    Name = "${var.cluster_identifier}-primary-instance-${count.index}"
    Role = count.index == 0 ? "writer" : "reader"
  }
}

##################################################
# Secondary Cluster — us-west-2 (DR)
##################################################

resource "aws_rds_cluster" "secondary" {
  provider = aws.secondary

  cluster_identifier        = "${var.cluster_identifier}-secondary"
  engine                    = "aurora-mysql"
  engine_version            = var.engine_version
  global_cluster_identifier = aws_rds_global_cluster.this.id

  # Secondary clusters managed by global cluster replication
  # master credentials not set here — inherited from primary

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "04:00-05:00"
  preferred_maintenance_window = "sun:06:00-sun:07:00"

  storage_encrypted   = true
  deletion_protection = true

  enabled_cloudwatch_logs_exports = ["audit", "error"]

  db_subnet_group_name   = aws_db_subnet_group.secondary.name
  vpc_security_group_ids = [aws_security_group.aurora_secondary.id]

  tags = {
    Name        = "${var.cluster_identifier}-secondary"
    Role        = "secondary-reader"
    Environment = "production"
    ManagedBy   = "terraform"
  }

  depends_on = [aws_rds_cluster_instance.primary]

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      replication_source_identifier,
      global_cluster_identifier
    ]
  }
}

resource "aws_rds_cluster_instance" "secondary" {
  count = 1

  provider = aws.secondary

  identifier         = "${var.cluster_identifier}-secondary-${count.index}"
  cluster_identifier = aws_rds_cluster.secondary.id
  instance_class     = var.instance_class
  engine             = "aurora-mysql"
  engine_version     = var.engine_version

  performance_insights_enabled = true
  monitoring_interval          = 30
  monitoring_role_arn          = aws_iam_role.rds_enhanced_monitoring_secondary.arn

  tags = {
    Name = "${var.cluster_identifier}-secondary-instance-${count.index}"
    Role = "dr-reader"
  }
}

##################################################
# Replication Lag Monitoring
##################################################

resource "aws_cloudwatch_metric_alarm" "aurora_replication_lag" {
  provider = aws.secondary

  alarm_name          = "aurora-global-replication-lag-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraGlobalDBReplicationLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1000 # 1 second in milliseconds
  alarm_description   = "Aurora Global DB replication lag exceeded 1 second — investigate immediately"
  alarm_actions       = [var.replication_lag_alarm_sns]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.secondary.cluster_identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "aurora_replication_lag_critical" {
  provider = aws.secondary

  alarm_name          = "aurora-global-replication-lag-critical"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "AuroraGlobalDBReplicationLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 30000 # 30 seconds — initiate DR
  alarm_description   = "CRITICAL: Aurora replication lag >30s — DR failover may be needed"
  alarm_actions       = [var.replication_lag_alarm_sns]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.secondary.cluster_identifier
  }
}

##################################################
# IAM Role for Enhanced Monitoring
##################################################

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "rds-enhanced-monitoring-primary"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_iam_role" "rds_enhanced_monitoring_secondary" {
  provider = aws.secondary
  name     = "rds-enhanced-monitoring-secondary"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring_secondary" {
  provider   = aws.secondary
  role       = aws_iam_role.rds_enhanced_monitoring_secondary.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

##################################################
# Outputs
##################################################

output "global_cluster_id" {
  value       = aws_rds_global_cluster.this.id
  description = "Aurora Global Cluster ID"
}

output "primary_cluster_endpoint" {
  value       = aws_rds_cluster.primary.endpoint
  description = "Primary cluster writer endpoint"
  sensitive   = true
}

output "primary_reader_endpoint" {
  value       = aws_rds_cluster.primary.reader_endpoint
  description = "Primary cluster reader endpoint"
  sensitive   = true
}

output "secondary_reader_endpoint" {
  value       = aws_rds_cluster.secondary.reader_endpoint
  description = "Secondary (DR) cluster reader endpoint"
  sensitive   = true
}

output "primary_cluster_arn" {
  value = aws_rds_cluster.primary.arn
}

output "secondary_cluster_arn" {
  value = aws_rds_cluster.secondary.arn
}
