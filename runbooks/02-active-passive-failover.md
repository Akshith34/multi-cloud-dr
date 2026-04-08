# Runbook: Active-Passive DR Failover
**Severity**: P1 | **RTO Target**: 15 minutes | **RPO Target**: 30 seconds

> **Purpose**: Step-by-step guide for on-call engineers to execute an active-passive DR failover from AWS `us-east-1` (primary) to `us-west-2` (secondary). Follow each step in order. Do not skip ahead.

---

## Pre-Conditions: When to Use This Runbook

Trigger this runbook when **ALL** of the following are true:

- [ ] PagerDuty alert fired for `route53-primary-health-check-failed` (3+ consecutive failures)
- [ ] AWS us-east-1 confirmed unhealthy (CloudWatch dashboard, manual HTTP check)
- [ ] Engineering manager / incident commander has approved failover
- [ ] This is NOT a false positive (confirmed via `health-check.sh` output)

> ⚠️ **Do not failover for a single health check failure.** Route 53 will handle transient failures automatically. This runbook is for a confirmed regional outage.

---

## Step 0: Create Incident (2 min)

1. Open PagerDuty and create a new incident:
   - Title: `DR FAILOVER — us-east-1 regional outage — [DATE]`
   - Severity: P1
   - Assign to: On-call SRE + DB on-call

2. Open Slack `#incident-response` and post:
   ```
   🚨 P1 INCIDENT — DR FAILOVER IN PROGRESS
   Primary region: us-east-1 — UNHEALTHY
   Failing over to: us-west-2
   Runbook: https://github.com/yourorg/multi-cloud-dr/blob/main/runbooks/02-active-passive-failover.md
   Incident commander: @yourname
   ```

3. Start the incident timer.

---

## Step 1: Validate Failure (3 min)

Run the health check script from a terminal with AWS credentials:

```bash
# From your local machine or Cloud9 in a healthy region (us-west-2)
./scripts/health-check.sh --region us-east-1 --verbose

# Expected output for failed region:
# [FAIL] us-east-1 ALB: HTTP 000 (connection timeout)
# [FAIL] us-east-1 Aurora writer: unreachable
# [OK]   us-west-2 ALB: HTTP 200
# [OK]   us-west-2 Aurora replica: lag=18ms
```

Also validate manually:
```bash
curl -v --max-time 10 https://app-primary.us-east-1.internal/health
# Should timeout or return 5xx
```

**Stop here if us-east-1 is partially healthy** — escalate to Incident Commander before proceeding.

---

## Step 2: Check Replication Lag (2 min)

Before failover, confirm Aurora replication lag is within acceptable range:

```bash
./scripts/validate-replication.sh --cluster prod-aurora-global-secondary

# Expected output:
# Aurora Global DB Replication Lag: 22ms ✅ (threshold: <30,000ms)
# S3 Replication Pending Objects: 3 (4.2 MB) ✅
# Last successful replication: 18 seconds ago ✅
```

If replication lag is **>30 seconds**, note it in the incident — data may be at risk. Confirm with Incident Commander before proceeding.

---

## Step 3: Execute Automated Failover (5 min)

**Option A — Automated (preferred):** Trigger the Lambda orchestrator:

```bash
aws lambda invoke \
  --function-name dr-orchestrator-prod \
  --region us-east-1 \
  --payload '{
    "action": "failover",
    "trigger": "manual",
    "target_region": "us-west-2",
    "dry_run": false,
    "initiated_by": "YOUR_EMAIL",
    "incident_id": "INC-XXXXX"
  }' \
  --cli-binary-format raw-in-base64-out \
  /tmp/dr-response.json

cat /tmp/dr-response.json
# Expected: {"status": "COMPLETED", "steps_completed": [...]}
```

**Option B — Manual (if Lambda fails):**

```bash
# 3a. Promote Aurora secondary to writer
aws rds failover-global-cluster \
  --global-cluster-identifier prod-aurora-global \
  --target-db-cluster-identifier arn:aws:rds:us-west-2:ACCOUNT:cluster:prod-aurora-global-secondary \
  --region us-east-1

# 3b. Monitor promotion (wait for "available" status)
watch -n 15 "aws rds describe-global-clusters \
  --global-cluster-identifier prod-aurora-global \
  --query 'GlobalClusters[0].Status' \
  --output text \
  --region us-east-1"

# 3c. Route 53 failover is automatic via health checks
# Verify DNS is propagating:
watch -n 10 "dig +short app.yourdomain.com"
# Should switch from us-east-1 IP to us-west-2 IP
```

---

## Step 4: Validate Failover Success (3 min)

```bash
# Confirm DNS has propagated to secondary
dig +short app.yourdomain.com
# Expected: us-west-2 load balancer IP

# Confirm application is responding
curl -v https://app.yourdomain.com/health
# Expected: HTTP 200 {"status":"healthy","region":"us-west-2"}

# Confirm Aurora writer is in us-west-2
aws rds describe-global-clusters \
  --global-cluster-identifier prod-aurora-global \
  --query 'GlobalClusters[0].GlobalClusterMembers[?IsWriter==`true`].DBClusterArn' \
  --output text

# Run full validation suite
./scripts/dr-drill.sh --validate-only --region us-west-2
```

---

## Step 5: Post-Failover Monitoring (30 min)

After failover, monitor these signals for 30 minutes:

| Signal | Where to Check | Alert Threshold |
|--------|---------------|-----------------|
| Error rate | CloudWatch → `prod/api/errors` | >1% |
| P99 latency | CloudWatch → `prod/api/latency` | >2000ms |
| Aurora connections | CloudWatch → `DatabaseConnections` | Near max |
| S3 replication lag | S3 → Metrics | >15 min |

Post updates to `#incident-response` every 10 minutes.

---

## Step 6: Incident Wrap-Up

Once stable (>30 min healthy in us-west-2):

1. Mark PagerDuty incident as "Monitoring"
2. Post in Slack: `✅ DR FAILOVER STABLE — Application running in us-west-2`
3. Schedule a Post-Incident Review (PIR) within 48 hours
4. Begin planning failback using: `runbooks/04-rollback-procedures.md`
5. File DR drill results in `fis/experiments/` and update the drill results table in `README.md`

---

## Escalation Contacts

| Role | Contact | When |
|------|---------|------|
| SRE Lead | `@sre-lead` / PD rotation | Any step fails |
| DBA On-Call | `@dba-oncall` / PD rotation | Aurora issues |
| Cloud Platform | `@cloud-platform` | Route 53 / networking |
| Eng Manager | Slack DM | Approval needed |

---

## Common Issues & Fixes

**Aurora promotion takes >10 minutes:**
```bash
# Check if there are pending transactions on the old writer
aws rds describe-db-clusters \
  --db-cluster-identifier prod-aurora-global-primary \
  --query 'DBClusters[0].Status'
# If "failing-over" — normal, keep waiting (max 15 min)
```

**DNS not switching after 5 minutes:**
```bash
# Force Route 53 health check re-evaluation
aws route53 get-health-check-status \
  --health-check-id YOUR_HC_ID
# If status shows "Healthy" — manually update record weights
```

**Application still connecting to old DB after DNS switch:**
- Connection pools may hold old endpoints
- Trigger a rolling restart of application pods:
  ```bash
  kubectl rollout restart deployment/api-server -n production
  ```
