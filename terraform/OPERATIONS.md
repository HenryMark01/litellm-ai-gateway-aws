# LiteLLM AWS Infrastructure Operations Guide

This document provides runbooks for common operational procedures for the LiteLLM AWS deployment. All procedures assume you have AWS CLI configured with appropriate permissions.

## Table of Contents

1. [Environment Variables](#environment-variables)
2. [ECS Service Force Deployment](#ecs-service-force-deployment)
3. [Terraform State Recovery](#terraform-state-recovery)
4. [Database Backup and Restore](#database-backup-and-restore)
5. [Secret Rotation](#secret-rotation)
6. [Monitoring and Alerting Setup](#monitoring-and-alerting-setup)
7. [Troubleshooting](#troubleshooting)

---

## Environment Variables

Before running any commands, set these environment variables based on your deployment:

```bash
# Core identifiers (from your tfvars file)
export TENANT="acme"
export ENVIRONMENT="staging"
export AWS_REGION="us-east-1"

# Derived resource names
export CLUSTER_NAME="${TENANT}-litellm-${ENVIRONMENT}"
export STATE_BUCKET="${TENANT}-${ENVIRONMENT}-litellm-state"
export CONFIG_BUCKET="${TENANT}-${ENVIRONMENT}-litellm-config"
export STATE_KEY="${TENANT}/litellm/${ENVIRONMENT}/terraform.tfstate"

# ECS Service names
export GATEWAY_SERVICE="gateway"
export BACKEND_SERVICE="backend"
export UI_SERVICE="ui"

# Database identifiers
export DB_CLUSTER_ID="${TENANT}-litellm-${ENVIRONMENT}"

# Secrets paths
export SECRETS_PREFIX="/${TENANT}/${ENVIRONMENT}/litellm"
```

---

## ECS Service Force Deployment

Use force deployment to pull new container images, reload secrets, or restart services after configuration changes.

### When to Use

- After updating secrets in Secrets Manager
- After updating config.yaml in S3
- To restart unhealthy services
- After container image updates (with same tag)

### Procedure: Force Deploy Single Service

```bash
# Force deploy gateway service
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${GATEWAY_SERVICE}" \
  --force-new-deployment \
  --region "${AWS_REGION}"

# Force deploy backend service
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${BACKEND_SERVICE}" \
  --force-new-deployment \
  --region "${AWS_REGION}"

# Force deploy UI service
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${UI_SERVICE}" \
  --force-new-deployment \
  --region "${AWS_REGION}"
```

### Procedure: Force Deploy All Services

```bash
for SERVICE in gateway backend ui; do
  echo "Force deploying ${SERVICE}..."
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${SERVICE}" \
    --force-new-deployment \
    --region "${AWS_REGION}"
done
```

### Verify Deployment Status

```bash
# Check service deployment status
aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${GATEWAY_SERVICE}" \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount}' \
  --region "${AWS_REGION}"

# Watch deployment progress
watch -n 5 "aws ecs describe-services \
  --cluster ${CLUSTER_NAME} \
  --services ${GATEWAY_SERVICE} \
  --query 'services[0].deployments[*].{Status:status,Running:runningCount,Desired:desiredCount,Pending:pendingCount}' \
  --region ${AWS_REGION}"

# View recent service events (useful for troubleshooting)
aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${GATEWAY_SERVICE}" \
  --query 'services[0].events[:10].{Time:createdAt,Message:message}' \
  --region "${AWS_REGION}"
```

### Rollback (if deployment fails)

If a deployment fails, ECS will keep the old tasks running. To explicitly rollback:

```bash
# Get the previous task definition revision
CURRENT_TASK_DEF=$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${GATEWAY_SERVICE}" \
  --query 'services[0].taskDefinition' \
  --output text \
  --region "${AWS_REGION}")

# Extract family name and get previous revision
TASK_FAMILY=$(echo ${CURRENT_TASK_DEF} | sed 's/:/ /g' | awk -F'/' '{print $NF}' | awk '{print $1}')
CURRENT_REV=$(echo ${CURRENT_TASK_DEF} | sed 's/:/ /g' | awk '{print $NF}')
PREV_REV=$((CURRENT_REV - 1))

# Update service to use previous task definition
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${GATEWAY_SERVICE}" \
  --task-definition "${TASK_FAMILY}:${PREV_REV}" \
  --region "${AWS_REGION}"
```

---

## Terraform State Recovery

The Terraform state is stored in S3 with versioning enabled. This allows recovery from state corruption or accidental modifications.

### Prerequisites

- State bucket: `${TENANT}-${ENVIRONMENT}-litellm-state`
- State key: `${TENANT}/litellm/${ENVIRONMENT}/terraform.tfstate`
- S3 versioning must be enabled (configured by bootstrap module)

### Procedure: List State Versions

```bash
# List all versions of the state file
aws s3api list-object-versions \
  --bucket "${STATE_BUCKET}" \
  --prefix "${STATE_KEY}" \
  --query 'Versions[*].{VersionId:VersionId,LastModified:LastModified,Size:Size}' \
  --region "${AWS_REGION}"

# Store version IDs for reference
aws s3api list-object-versions \
  --bucket "${STATE_BUCKET}" \
  --prefix "${STATE_KEY}" \
  --query 'Versions[*].VersionId' \
  --output text \
  --region "${AWS_REGION}"
```

### Procedure: Download State Version for Inspection

```bash
# Download a specific version to inspect before restoring
VERSION_ID="your-version-id-here"

aws s3api get-object \
  --bucket "${STATE_BUCKET}" \
  --key "${STATE_KEY}" \
  --version-id "${VERSION_ID}" \
  ./terraform.tfstate.backup \
  --region "${AWS_REGION}"

# Inspect the downloaded state
terraform show -json ./terraform.tfstate.backup | jq '.values.root_module.resources | length'
```

### Procedure: Restore State from Previous Version

**⚠️ CAUTION:** This overwrites the current state. Ensure you have backed up the current state first.

```bash
# Step 1: Backup current state
aws s3 cp \
  "s3://${STATE_BUCKET}/${STATE_KEY}" \
  "./terraform.tfstate.current.backup" \
  --region "${AWS_REGION}"

# Step 2: Download the version to restore
VERSION_ID="your-version-id-here"
aws s3api get-object \
  --bucket "${STATE_BUCKET}" \
  --key "${STATE_KEY}" \
  --version-id "${VERSION_ID}" \
  ./terraform.tfstate.restore \
  --region "${AWS_REGION}"

# Step 3: Upload restored state as new current version
aws s3 cp \
  ./terraform.tfstate.restore \
  "s3://${STATE_BUCKET}/${STATE_KEY}" \
  --region "${AWS_REGION}"

# Step 4: Verify restoration
terraform init
terraform plan  # Should show no changes if restored correctly
```

### Procedure: Force Unlock State (Stale Lock)

Terraform 1.10+ uses S3-native locking with `use_lockfile = true`. If a lock becomes stale:

```bash
# Check for lock file
aws s3 ls "s3://${STATE_BUCKET}/${STATE_KEY}.tflock" --region "${AWS_REGION}"

# Remove stale lock (only if you're certain no other process is running!)
aws s3 rm "s3://${STATE_BUCKET}/${STATE_KEY}.tflock" --region "${AWS_REGION}"

# Alternative: Use terraform force-unlock (preferred method)
# First, get the lock ID from the error message, then:
terraform force-unlock <LOCK_ID>
```

---

## Database Backup and Restore

Aurora PostgreSQL has automated daily backups with 7-day retention. Manual snapshots can be created for longer retention or before major changes.

### Procedure: Create Manual Snapshot

```bash
# Create a manual snapshot before major changes
SNAPSHOT_ID="${DB_CLUSTER_ID}-manual-$(date +%Y%m%d-%H%M%S)"

aws rds create-db-cluster-snapshot \
  --db-cluster-identifier "${DB_CLUSTER_ID}" \
  --db-cluster-snapshot-identifier "${SNAPSHOT_ID}" \
  --region "${AWS_REGION}"

# Wait for snapshot to complete
aws rds wait db-cluster-snapshot-available \
  --db-cluster-snapshot-identifier "${SNAPSHOT_ID}" \
  --region "${AWS_REGION}"

echo "Snapshot ${SNAPSHOT_ID} created successfully"
```

### Procedure: List Available Snapshots

```bash
# List automated snapshots (last 7 days)
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier "${DB_CLUSTER_ID}" \
  --snapshot-type automated \
  --query 'DBClusterSnapshots[*].{ID:DBClusterSnapshotIdentifier,Created:SnapshotCreateTime,Status:Status}' \
  --region "${AWS_REGION}"

# List manual snapshots
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier "${DB_CLUSTER_ID}" \
  --snapshot-type manual \
  --query 'DBClusterSnapshots[*].{ID:DBClusterSnapshotIdentifier,Created:SnapshotCreateTime,Status:Status}' \
  --region "${AWS_REGION}"
```

### Procedure: Point-in-Time Recovery

Restore the database to any point within the backup retention period:

```bash
# Get available restore window
aws rds describe-db-clusters \
  --db-cluster-identifier "${DB_CLUSTER_ID}" \
  --query 'DBClusters[0].{EarliestRestoreTime:EarliestRestorableTime,LatestRestoreTime:LatestRestorableTime}' \
  --region "${AWS_REGION}"

# Restore to a specific point in time (creates new cluster)
RESTORE_TIME="2024-01-15T10:30:00Z"  # ISO 8601 format
NEW_CLUSTER_ID="${DB_CLUSTER_ID}-restored"

aws rds restore-db-cluster-to-point-in-time \
  --source-db-cluster-identifier "${DB_CLUSTER_ID}" \
  --db-cluster-identifier "${NEW_CLUSTER_ID}" \
  --restore-to-time "${RESTORE_TIME}" \
  --vpc-security-group-ids "sg-xxx" \
  --db-subnet-group-name "${DB_CLUSTER_ID}-subnet-group" \
  --region "${AWS_REGION}"

# Wait for cluster restoration
aws rds wait db-cluster-available \
  --db-cluster-identifier "${NEW_CLUSTER_ID}" \
  --region "${AWS_REGION}"

# Create a new instance in the restored cluster
aws rds create-db-instance \
  --db-cluster-identifier "${NEW_CLUSTER_ID}" \
  --db-instance-identifier "${NEW_CLUSTER_ID}-instance" \
  --db-instance-class "db.t4g.medium" \
  --engine "aurora-postgresql" \
  --region "${AWS_REGION}"
```

### Procedure: Restore from Snapshot

```bash
SNAPSHOT_ID="your-snapshot-identifier"
NEW_CLUSTER_ID="${DB_CLUSTER_ID}-restored"

# Restore from snapshot (creates new cluster)
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier "${NEW_CLUSTER_ID}" \
  --snapshot-identifier "${SNAPSHOT_ID}" \
  --engine "aurora-postgresql" \
  --vpc-security-group-ids "sg-xxx" \
  --db-subnet-group-name "${DB_CLUSTER_ID}-subnet-group" \
  --region "${AWS_REGION}"

# Wait and create instance (same as above)
```

### Procedure: Emergency Database Access via Bastion

For direct database access (schema changes, debugging):

```bash
# 1. Get bastion host IP (if enabled)
BASTION_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${TENANT}-litellm-${ENVIRONMENT}-bastion" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "${AWS_REGION}")

# 2. Get database endpoint
DB_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "${DB_CLUSTER_ID}" \
  --query 'DBClusters[0].Endpoint' \
  --output text \
  --region "${AWS_REGION}")

# 3. Get master password from Secrets Manager
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${SECRETS_PREFIX}/db-master-password" \
  --query 'SecretString' \
  --output text \
  --region "${AWS_REGION}")

# 4. SSH tunnel through bastion
ssh -i your-key.pem -L 5432:${DB_ENDPOINT}:5432 ec2-user@${BASTION_IP}

# 5. In another terminal, connect via localhost
psql -h localhost -U postgres -d litellm
# Enter password when prompted
```

---

## Secret Rotation

Secrets are stored in AWS Secrets Manager. After updating secrets, ECS services must be redeployed to pick up new values.

### Secret Paths

| Secret | Path |
|--------|------|
| LiteLLM Master Key | `/${TENANT}/${ENVIRONMENT}/litellm/master-key` |
| LiteLLM Salt Key | `/${TENANT}/${ENVIRONMENT}/litellm/salt-key` |
| Database Master Password | `/${TENANT}/${ENVIRONMENT}/litellm/db-master-password` |
| OpenAI API Key | `/${TENANT}/${ENVIRONMENT}/litellm/openai-api-key` |
| Anthropic API Key | `/${TENANT}/${ENVIRONMENT}/litellm/anthropic-api-key` |

### Procedure: Rotate Provider API Key (OpenAI/Anthropic)

```bash
# 1. Update the secret value
SECRET_NAME="${SECRETS_PREFIX}/openai-api-key"
NEW_API_KEY="sk-new-key-value-here"

aws secretsmanager put-secret-value \
  --secret-id "${SECRET_NAME}" \
  --secret-string "${NEW_API_KEY}" \
  --region "${AWS_REGION}"

# 2. Force deploy services to pick up new secret
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${GATEWAY_SERVICE}" \
  --force-new-deployment \
  --region "${AWS_REGION}"

aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${BACKEND_SERVICE}" \
  --force-new-deployment \
  --region "${AWS_REGION}"

# 3. Verify deployment
aws ecs wait services-stable \
  --cluster "${CLUSTER_NAME}" \
  --services "${GATEWAY_SERVICE}" "${BACKEND_SERVICE}" \
  --region "${AWS_REGION}"

echo "Secret rotation complete and services redeployed"
```

### Procedure: Rotate LiteLLM Master Key

**⚠️ CAUTION:** Rotating the master key will invalidate existing API keys. Coordinate with users.

```bash
# 1. Generate new master key
NEW_MASTER_KEY="sk-$(openssl rand -hex 32)"

# 2. Update in Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id "${SECRETS_PREFIX}/master-key" \
  --secret-string "${NEW_MASTER_KEY}" \
  --region "${AWS_REGION}"

# 3. Force deploy all services
for SERVICE in gateway backend ui; do
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${SERVICE}" \
    --force-new-deployment \
    --region "${AWS_REGION}"
done

# 4. Wait for stability
aws ecs wait services-stable \
  --cluster "${CLUSTER_NAME}" \
  --services gateway backend ui \
  --region "${AWS_REGION}"

# 5. Test with new master key
curl -X GET "${LITELLM_ENDPOINT}/v1/models" \
  -H "Authorization: Bearer ${NEW_MASTER_KEY}"
```

### Procedure: View Secret Value (for verification)

```bash
# Get current secret value
aws secretsmanager get-secret-value \
  --secret-id "${SECRETS_PREFIX}/master-key" \
  --query 'SecretString' \
  --output text \
  --region "${AWS_REGION}"
```

### Procedure: View Secret Rotation History

```bash
# List secret versions
aws secretsmanager list-secret-version-ids \
  --secret-id "${SECRETS_PREFIX}/openai-api-key" \
  --query 'Versions[*].{VersionId:VersionId,Created:CreatedDate,Stages:VersionStages}' \
  --region "${AWS_REGION}"
```

---

## Monitoring and Alerting Setup

### CloudWatch Log Groups

The deployment creates the following log groups:

| Log Group | Content |
|-----------|---------|
| `/ecs/${TENANT}-litellm-${ENVIRONMENT}/gateway` | Gateway API logs |
| `/ecs/${TENANT}-litellm-${ENVIRONMENT}/backend` | Backend service logs |
| `/ecs/${TENANT}-litellm-${ENVIRONMENT}/ui` | UI service logs |
| `/ecs/${TENANT}-litellm-${ENVIRONMENT}/migrations` | Database migration logs |

### Procedure: View Recent Logs

```bash
# View gateway logs (last 30 minutes)
aws logs filter-log-events \
  --log-group-name "/ecs/${CLUSTER_NAME}/gateway" \
  --start-time $(( $(date +%s) - 1800 ))000 \
  --region "${AWS_REGION}"

# Stream gateway logs in real-time
aws logs tail "/ecs/${CLUSTER_NAME}/gateway" --follow --region "${AWS_REGION}"

# Filter for errors only
aws logs filter-log-events \
  --log-group-name "/ecs/${CLUSTER_NAME}/gateway" \
  --filter-pattern "ERROR" \
  --start-time $(( $(date +%s) - 3600 ))000 \
  --region "${AWS_REGION}"
```

### Procedure: Search Logs for Specific Request

```bash
# Search by request ID
REQUEST_ID="abc123"
aws logs filter-log-events \
  --log-group-name "/ecs/${CLUSTER_NAME}/gateway" \
  --filter-pattern "${REQUEST_ID}" \
  --start-time $(( $(date +%s) - 86400 ))000 \
  --region "${AWS_REGION}"
```

### Procedure: Create CloudWatch Dashboard

```bash
# Create a basic monitoring dashboard
cat > dashboard.json << 'EOF'
{
  "widgets": [
    {
      "type": "metric",
      "x": 0, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "ECS CPU Utilization",
        "metrics": [
          ["AWS/ECS", "CPUUtilization", "ClusterName", "${CLUSTER_NAME}", "ServiceName", "gateway"],
          ["...", "backend"],
          ["...", "ui"]
        ],
        "period": 300,
        "stat": "Average"
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "ECS Memory Utilization",
        "metrics": [
          ["AWS/ECS", "MemoryUtilization", "ClusterName", "${CLUSTER_NAME}", "ServiceName", "gateway"],
          ["...", "backend"],
          ["...", "ui"]
        ],
        "period": 300,
        "stat": "Average"
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "ALB Request Count",
        "metrics": [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "${ALB_ARN_SUFFIX}"]
        ],
        "period": 60,
        "stat": "Sum"
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 6, "width": 12, "height": 6,
      "properties": {
        "title": "ALB 5XX Errors",
        "metrics": [
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "${ALB_ARN_SUFFIX}"]
        ],
        "period": 60,
        "stat": "Sum"
      }
    }
  ]
}
EOF

# Create the dashboard
aws cloudwatch put-dashboard \
  --dashboard-name "${TENANT}-litellm-${ENVIRONMENT}" \
  --dashboard-body file://dashboard.json \
  --region "${AWS_REGION}"
```

### Procedure: Create Error Rate Alarm

```bash
# Create alarm for 5XX error rate
aws cloudwatch put-metric-alarm \
  --alarm-name "${CLUSTER_NAME}-high-error-rate" \
  --alarm-description "LiteLLM 5XX error rate > 5%" \
  --metric-name "HTTPCode_Target_5XX_Count" \
  --namespace "AWS/ApplicationELB" \
  --statistic Sum \
  --period 300 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --dimensions Name=LoadBalancer,Value="${ALB_ARN_SUFFIX}" \
  --region "${AWS_REGION}"
```

### Procedure: Create SNS Topic for Alerts

```bash
# Create SNS topic
SNS_TOPIC_ARN=$(aws sns create-topic \
  --name "${CLUSTER_NAME}-alerts" \
  --query 'TopicArn' \
  --output text \
  --region "${AWS_REGION}")

# Subscribe email to topic
aws sns subscribe \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --protocol email \
  --notification-endpoint "ops@example.com" \
  --region "${AWS_REGION}"

echo "SNS Topic ARN: ${SNS_TOPIC_ARN}"
echo "Check email to confirm subscription"
```

### Procedure: View Alarm Status

```bash
# List all alarms for this environment
aws cloudwatch describe-alarms \
  --alarm-name-prefix "${CLUSTER_NAME}" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
  --region "${AWS_REGION}"
```

---

## Troubleshooting

### ECS Task Not Starting

```bash
# Check service events for errors
aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${GATEWAY_SERVICE}" \
  --query 'services[0].events[:10]' \
  --region "${AWS_REGION}"

# Check stopped task reasons
aws ecs list-tasks \
  --cluster "${CLUSTER_NAME}" \
  --service-name "${GATEWAY_SERVICE}" \
  --desired-status STOPPED \
  --region "${AWS_REGION}"

# Get details of stopped task
TASK_ARN="arn:aws:ecs:..."  # from above command
aws ecs describe-tasks \
  --cluster "${CLUSTER_NAME}" \
  --tasks "${TASK_ARN}" \
  --query 'tasks[0].{Status:lastStatus,StopReason:stoppedReason,StopCode:stopCode}' \
  --region "${AWS_REGION}"
```

### Health Check Failures

```bash
# Check ALB target health
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --names "${CLUSTER_NAME}-gateway" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "${AWS_REGION}")

aws elbv2 describe-target-health \
  --target-group-arn "${TARGET_GROUP_ARN}" \
  --region "${AWS_REGION}"

# Test health endpoint directly (from bastion or local with VPN)
curl -v http://${ALB_DNS}/health/liveliness
curl -v http://${ALB_DNS}/health/readiness
```

### Database Connection Issues

```bash
# Check security group rules
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*${CLUSTER_NAME}*rds*" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "${AWS_REGION}")

aws ec2 describe-security-groups \
  --group-ids "${SG_ID}" \
  --query 'SecurityGroups[0].IpPermissions' \
  --region "${AWS_REGION}"

# Check database status
aws rds describe-db-clusters \
  --db-cluster-identifier "${DB_CLUSTER_ID}" \
  --query 'DBClusters[0].{Status:Status,Endpoint:Endpoint}' \
  --region "${AWS_REGION}"
```

### Configuration Not Loading

```bash
# Verify config file exists in S3
aws s3 ls "s3://${CONFIG_BUCKET}/config.yaml" --region "${AWS_REGION}"

# Download and verify config syntax
aws s3 cp "s3://${CONFIG_BUCKET}/config.yaml" ./config.yaml --region "${AWS_REGION}"
python -c "import yaml; yaml.safe_load(open('config.yaml'))"

# Check task role can access S3
TASK_ROLE_ARN=$(aws ecs describe-task-definition \
  --task-definition "${CLUSTER_NAME}-gateway" \
  --query 'taskDefinition.taskRoleArn' \
  --output text \
  --region "${AWS_REGION}")

echo "Task Role: ${TASK_ROLE_ARN}"
# Verify role has S3 read permissions
```

### Quick Health Check Script

```bash
#!/bin/bash
# health-check.sh - Quick system health check

echo "=== LiteLLM Health Check ==="
echo ""

# ECS Services
echo "ECS Services:"
aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services gateway backend ui \
  --query 'services[*].{Service:serviceName,Status:status,Running:runningCount,Desired:desiredCount}' \
  --output table \
  --region "${AWS_REGION}"

echo ""

# ALB Health
echo "ALB Target Health (Gateway):"
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --names "${CLUSTER_NAME}-gateway" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null)

if [ -n "$TARGET_GROUP_ARN" ]; then
  aws elbv2 describe-target-health \
    --target-group-arn "${TARGET_GROUP_ARN}" \
    --query 'TargetHealthDescriptions[*].{Target:Target.Id,Health:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table \
    --region "${AWS_REGION}"
else
  echo "Target group not found"
fi

echo ""

# Database
echo "Database Status:"
aws rds describe-db-clusters \
  --db-cluster-identifier "${DB_CLUSTER_ID}" \
  --query 'DBClusters[0].{Status:Status,Engine:Engine,Endpoint:Endpoint}' \
  --output table \
  --region "${AWS_REGION}" 2>/dev/null || echo "Database cluster not found"

echo ""

# Recent Errors
echo "Recent Errors (last 5 minutes):"
aws logs filter-log-events \
  --log-group-name "/ecs/${CLUSTER_NAME}/gateway" \
  --filter-pattern "ERROR" \
  --start-time $(( $(date +%s) - 300 ))000 \
  --max-items 5 \
  --query 'events[*].message' \
  --region "${AWS_REGION}" 2>/dev/null || echo "No recent errors or log group not found"

echo ""
echo "=== Health Check Complete ==="
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Force deploy gateway | `aws ecs update-service --cluster ${CLUSTER_NAME} --service gateway --force-new-deployment` |
| View logs | `aws logs tail /ecs/${CLUSTER_NAME}/gateway --follow` |
| Get master key | `aws secretsmanager get-secret-value --secret-id ${SECRETS_PREFIX}/master-key --query SecretString --output text` |
| Create DB snapshot | `aws rds create-db-cluster-snapshot --db-cluster-identifier ${DB_CLUSTER_ID} --db-cluster-snapshot-identifier snapshot-$(date +%Y%m%d)` |
| Check service health | `aws ecs describe-services --cluster ${CLUSTER_NAME} --services gateway` |
| List state versions | `aws s3api list-object-versions --bucket ${STATE_BUCKET} --prefix ${STATE_KEY}` |

---

## Related Documentation

- [Terraform Documentation](./README.md)
- [LiteLLM Official Docs](https://docs.litellm.ai/)
- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [Aurora PostgreSQL Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/)
