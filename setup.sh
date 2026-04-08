#!/usr/bin/env bash
# Package the project for GitHub upload
set -e

cd /home/claude/multi-cloud-dr

# Create remaining placeholder files to make structure complete
cat > .gitignore << 'EOF'
# Terraform
.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
!example.tfvars
.terraform.lock.hcl
terraform.tfplan

# Python
__pycache__/
*.pyc
*.pyo
.pytest_cache/
.coverage
coverage.xml

# AWS
.aws/

# Environment
.env
.env.local

# Logs
*.log
/tmp/

# IDE
.vscode/
.idea/
*.swp
EOF

# Example tfvars (safe to commit)
cat > terraform/aws/example.tfvars << 'EOF'
# Copy this to prod.tfvars and fill in your values
# DO NOT commit prod.tfvars — it's in .gitignore

aws_account_id     = "123456789012"
primary_region     = "us-east-1"
dr_region          = "us-west-2"
domain_name        = "app.yourdomain.com"
hosted_zone_id     = "Z1234567890ABC"
dr_mode            = "active-passive"  # or "active-active"
aurora_instance_class = "db.r6g.xlarge"
EOF

# Lambda requirements
cat > lambda/dr-orchestrator/requirements.txt << 'EOF'
boto3>=1.34.0
EOF

# Minimal Azure Terraform placeholder
mkdir -p terraform/azure/traffic-manager
cat > terraform/azure/traffic-manager/main.tf << 'EOF'
# Azure Traffic Manager — DR failover profile
# Mirrors Route 53 failover for multi-cloud DR

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

variable "resource_group_name" { type = string }
variable "location"            { type = string; default = "East US" }
variable "primary_endpoint"    { type = string }
variable "secondary_endpoint"  { type = string }

resource "azurerm_traffic_manager_profile" "dr" {
  name                = "dr-traffic-manager-profile"
  resource_group_name = var.resource_group_name

  traffic_routing_method = "Priority"

  dns_config {
    relative_name = "myapp-dr"
    ttl           = 60
  }

  monitor_config {
    protocol                     = "HTTPS"
    port                         = 443
    path                         = "/health"
    interval_in_seconds          = 10
    tolerance_in_seconds         = 30
    timeout_in_seconds           = 5
  }

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
    Purpose     = "disaster-recovery"
  }
}

resource "azurerm_traffic_manager_azure_endpoint" "primary" {
  name               = "primary-aws-endpoint"
  profile_id         = azurerm_traffic_manager_profile.dr.id
  priority           = 1
  target_resource_id = var.primary_endpoint
  enabled            = true
}

resource "azurerm_traffic_manager_azure_endpoint" "secondary" {
  name               = "secondary-azure-endpoint"
  profile_id         = azurerm_traffic_manager_profile.dr.id
  priority           = 2
  target_resource_id = var.secondary_endpoint
  enabled            = true
}
EOF

# GCP Terraform placeholder
mkdir -p terraform/gcp/cloud-dns
cat > terraform/gcp/cloud-dns/main.tf << 'EOF'
# GCP Cloud DNS — Failover routing for multi-cloud DR

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id"    { type = string }
variable "dns_zone_name" { type = string }
variable "domain_name"   { type = string }
variable "primary_ip"    { type = string }
variable "secondary_ip"  { type = string }

resource "google_dns_record_set" "primary" {
  name         = var.domain_name
  managed_zone = var.dns_zone_name
  type         = "A"
  ttl          = 60
  rrdatas      = [var.primary_ip]
  project      = var.project_id
}

# GCP health check for DR routing
resource "google_compute_http_health_check" "dr" {
  name               = "dr-health-check"
  request_path       = "/health"
  check_interval_sec = 10
  timeout_sec        = 5
  project            = var.project_id
}
EOF

# Validate-replication script stub
cat > scripts/validate-replication.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

VERBOSE=false
CLUSTER_ID="${CLUSTER_ID:-prod-aurora-global-secondary}"
REGION="${REGION:-us-west-2}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose) VERBOSE=true; shift ;;
    --cluster) CLUSTER_ID="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "Checking Aurora Global DB replication lag..."
LAG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name AuroraGlobalDBReplicationLag \
  --dimensions Name=DBClusterIdentifier,Value="${CLUSTER_ID}" \
  --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Maximum \
  --region "${REGION}" \
  --query 'Datapoints[0].Maximum' \
  --output text 2>/dev/null || echo "N/A")

echo "Aurora Replication Lag: ${LAG}ms"

if [[ "${LAG}" == "None" || "${LAG}" == "N/A" ]]; then
  echo "⚠️  No replication lag data found (cluster may be primary or metrics not available)"
elif (( $(echo "${LAG} > 30000" | bc -l 2>/dev/null || echo 0) )); then
  echo "❌ CRITICAL: Replication lag ${LAG}ms exceeds 30s threshold"
  exit 1
else
  echo "✅ Replication lag within acceptable range"
fi
EOF
chmod +x scripts/validate-replication.sh
chmod +x scripts/dr-drill.sh

echo "Project structure complete!"
find /home/claude/multi-cloud-dr -type f | sort
