# Multi-Cloud Disaster Recovery Architecture
### AWS + Azure + GCP | Active-Active & Active-Passive DR

[![DR Failover Tests](https://github.com/yourusername/multi-cloud-dr/actions/workflows/dr-test.yml/badge.svg)](https://github.com/yourusername/multi-cloud-dr/actions)
[![Terraform](https://img.shields.io/badge/Terraform-1.6+-623CE4?logo=terraform)](https://terraform.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Overview

This repository contains the **Infrastructure as Code (IaC), Lambda orchestration, FIS experiments, and operational runbooks** for a production-grade multi-cloud disaster recovery system spanning **AWS, Azure, and GCP**.

Designed to achieve **near-zero RPO/RTO** for critical workloads using:
- **AWS Route 53** failover routing (health-check driven)
- **Aurora Global Database** for cross-region replication (<1s lag)
- **S3 Cross-Region Replication (CRR)** for object storage DR
- **AWS Fault Injection Simulator (FIS)** for automated chaos testing
- **Lambda orchestration** for fully automated failover execution

> **Impact:** Reduced manual DR drill time from **2 days → ~2 hours** through full automation. Enabled on-call engineers to execute DR events independently via standardized runbooks.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Global DNS Layer                          │
│                    Route 53 (Failover Routing)                   │
│          Health Checks → Weighted → Latency → Failover          │
└──────────────┬──────────────────┬──────────────────┬────────────┘
               │                  │                  │
    ┌──────────▼──────┐  ┌────────▼──────┐  ┌───────▼───────┐
    │   AWS (PRIMARY) │  │  Azure (DR-1) │  │  GCP (DR-2)   │
    │                 │  │               │  │               │
    │  us-east-1      │  │ eastus        │  │ us-central1   │
    │  us-west-2      │  │ westus2       │  │ us-east1      │
    │                 │  │               │  │               │
    │  ┌───────────┐  │  │ ┌──────────┐  │  │ ┌──────────┐  │
    │  │  Aurora   │  │  │ │ Azure SQL│  │  │ │Cloud SQL │  │
    │  │  Global   │◄─┼──┼─┤ Replica  │  │  │ │ Replica  │  │
    │  │  Database │  │  │ └──────────┘  │  │ └──────────┘  │
    │  └───────────┘  │  │               │  │               │
    │  ┌───────────┐  │  │ ┌──────────┐  │  │ ┌──────────┐  │
    │  │    S3     │──┼──┼►│  Azure   │  │  │ │   GCS    │  │
    │  │   CRR     │  │  │ │  Blob    │  │  │ │  Mirror  │  │
    │  └───────────┘  │  │ └──────────┘  │  │ └──────────┘  │
    └─────────────────┘  └───────────────┘  └───────────────┘
```

### DR Strategies Implemented

| Pattern | Use Case | RTO | RPO |
|---------|----------|-----|-----|
| **Active-Active** | Stateless services, read traffic | <1 min | ~0s |
| **Active-Passive (Warm)** | Stateful DB workloads | 5–15 min | <30s |
| **Active-Passive (Cold)** | Non-critical batch systems | 1–4 hrs | <1 hr |

---

## Repository Structure

```
multi-cloud-dr/
├── terraform/
│   ├── aws/                    # AWS primary + DR region infra
│   │   ├── route53/            # Failover routing + health checks
│   │   ├── aurora-global/      # Aurora Global Database cluster
│   │   └── s3-replication/     # S3 CRR configuration
│   ├── azure/                  # Azure DR site infrastructure
│   │   ├── traffic-manager/    # Azure Traffic Manager profiles
│   │   └── sql-replica/        # Azure SQL geo-replica
│   ├── gcp/                    # GCP DR site infrastructure
│   │   ├── cloud-dns/          # GCP Cloud DNS failover
│   │   └── cloud-sql/          # Cloud SQL read replica
│   └── modules/                # Reusable Terraform modules
│       ├── aurora-global/
│       ├── route53-failover/
│       └── s3-replication/
├── lambda/
│   ├── dr-orchestrator/        # Main failover orchestration engine
│   ├── health-checker/         # Cross-cloud health validation
│   └── failover-validator/     # Post-failover validation suite
├── fis/
│   ├── experiments/            # FIS experiment templates (JSON)
│   └── templates/              # Reusable chaos scenarios
├── runbooks/
│   ├── 01-active-active-failover.md
│   ├── 02-active-passive-failover.md
│   ├── 03-database-failover.md
│   ├── 04-rollback-procedures.md
│   └── 05-post-dr-validation.md
├── scripts/
│   ├── dr-drill.sh             # Automated DR drill runner
│   ├── health-check.sh         # Multi-cloud health checker
│   └── validate-replication.sh # Replication lag monitor
├── docs/
│   ├── architecture-decisions/ # ADRs
│   └── runbook-guide.md
└── .github/
    └── workflows/
        ├── dr-test.yml         # Scheduled DR tests (CI/CD)
        └── terraform-plan.yml  # Infra validation on PR
```

---

## Key Components

### 1. Route 53 Failover Routing
- **Health checks** poll all regions every 10 seconds
- **Primary → Secondary failover** triggered automatically when health checks fail for 3 consecutive intervals
- **Weighted routing** used for active-active to distribute load 70/30 between AWS regions
- TTL set to **60s** for fast DNS propagation during failover

### 2. Aurora Global Database
- **Primary cluster**: `us-east-1` (writer)
- **Read replicas**: `us-west-2`, Azure via DMS sync, GCP via DMS
- **Replication lag** monitored via CloudWatch — alerts fire at >1 second
- **Managed planned failover**: promotes a secondary in <1 minute
- **RPO: <1 second** for in-region, **<30 seconds** cross-cloud

### 3. S3 Cross-Region Replication
- **Replication rules** target all objects with versioning enabled
- **Replication Time Control (RTC)** guarantees 99.99% of objects replicated within **15 minutes**
- **Replication metrics** fed into CloudWatch dashboard for real-time lag monitoring
- Azure Blob and GCS mirrored via EventBridge → Lambda → Storage SDKs

### 4. FIS Automated DR Testing
- Experiments simulate: AZ failure, region failure, network partition, DB writer failure
- **Lambda orchestration** runs full failover → validate → rollback sequence
- Results published to S3 + SNS for team notification
- Scheduled weekly via EventBridge to ensure DR stays current

---

## Getting Started

### Prerequisites
```bash
terraform >= 1.6
aws-cli >= 2.0
az cli >= 2.50
gcloud >= 450.0
python >= 3.11
```

### Deploy AWS Infrastructure
```bash
cd terraform/aws
terraform init
terraform plan -var-file="prod.tfvars"
terraform apply -var-file="prod.tfvars"
```

### Deploy Azure DR Site
```bash
cd terraform/azure
terraform init
terraform plan -var-file="dr.tfvars"
terraform apply -var-file="dr.tfvars"
```

### Run a DR Drill
```bash
# Full automated DR drill (active-passive failover + validation)
./scripts/dr-drill.sh --mode active-passive --target aws-us-west-2 --notify-slack

# Active-active weighted shift (shift 100% traffic to secondary)
./scripts/dr-drill.sh --mode active-active --weight 0:100 --duration 30m
```

### Trigger FIS Experiment
```bash
aws fis start-experiment \
  --experiment-template-id <template-id> \
  --region us-east-1
```

---

## Monitoring & Observability

| Signal | Tool | Alert Threshold |
|--------|------|-----------------|
| Replication lag | CloudWatch | >1s |
| Health check failures | Route 53 + SNS | 3 consecutive |
| Aurora failover events | CloudWatch Events | Any |
| S3 replication lag | S3 Replication Metrics | >15 min |
| Lambda orchestration errors | CloudWatch Logs | Any ERROR |

---

## DR Drill Results

| Date | Scenario | RTO Achieved | RPO Achieved | Result |
|------|----------|-------------|-------------|--------|
| 2024-Q4 | AZ failure (active-active) | 45s | 0s | ✅ PASS |
| 2024-Q4 | Region failure (active-passive) | 8 min | 22s | ✅ PASS |
| 2025-Q1 | Aurora writer failure | 4 min | <1s | ✅ PASS |
| 2025-Q1 | Full region black-hole | 12 min | 28s | ✅ PASS |

---

## Team Collaboration

- **SRE Team**: Validated failover procedures, owns Route 53 + FIS configuration
- **DBA Team**: Owns Aurora Global config, replication monitoring, and DB failover runbooks
- **App Teams**: Validated connection string failover, tested read-replica consistency
- **On-Call Engineers**: Trained on runbooks — can execute DR events independently

---

## License

MIT — see [LICENSE](LICENSE)
