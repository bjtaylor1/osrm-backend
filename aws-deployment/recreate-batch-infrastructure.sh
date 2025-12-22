#!/bin/bash

# Script to recreate AWS Batch infrastructure with updated configuration
# This is needed when you need to change the EBS volume size or other compute environment settings

set -euo pipefail

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
QUEUE_NAME="osrm-queue"
COMPUTE_ENV_NAME="osrm-compute-env"
JOB_DEFINITION_NAME="process-osrm-job"
EBS_VOLUME_SIZE="500"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --ebs-size)
            EBS_VOLUME_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            cat << 'EOF'
Recreate AWS Batch Infrastructure

This script safely deletes and recreates AWS Batch compute environment
and job queue to apply new configuration (e.g., larger EBS volumes).

Usage: ./recreate-batch-infrastructure.sh [OPTIONS]

OPTIONS:
    --region REGION    AWS region (default: us-east-1)
    --ebs-size GB      EBS volume size in GB (default: 500)
    -h, --help         Show this help

EXAMPLE:
    ./recreate-batch-infrastructure.sh --ebs-size 500
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

log "Starting AWS Batch infrastructure recreation"
log "Region: ${AWS_REGION}"
log "Target EBS Size: ${EBS_VOLUME_SIZE}GB"
log ""

# Step 1: Disable and delete job queue
log "Step 1/5: Disabling job queue: ${QUEUE_NAME}"
if aws batch describe-job-queues --job-queues "${QUEUE_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    aws batch update-job-queue \
        --job-queue "${QUEUE_NAME}" \
        --state DISABLED \
        --region "${AWS_REGION}" || log "Queue may already be disabled"
    
    log "Waiting for queue to be disabled..."
    sleep 5
    
    log "Deleting job queue: ${QUEUE_NAME}"
    aws batch delete-job-queue \
        --job-queue "${QUEUE_NAME}" \
        --region "${AWS_REGION}" || error "Failed to delete job queue"
    
    log "Waiting for queue deletion to complete (this may take 1-2 minutes)..."
    local max_wait=60
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if ! aws batch describe-job-queues --job-queues "${QUEUE_NAME}" --region "${AWS_REGION}" &>/dev/null; then
            log "✓ Queue deleted"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo ""
    
    if [ $elapsed -ge $max_wait ]; then
        log "Warning: Queue deletion taking longer than expected, continuing..."
        sleep 30
    fi
else
    log "Job queue doesn't exist, skipping"
fi

# Step 2: Disable and delete compute environment
log "Step 2/5: Disabling compute environment: ${COMPUTE_ENV_NAME}"
if aws batch describe-compute-environments --compute-environments "${COMPUTE_ENV_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    aws batch update-compute-environment \
        --compute-environment "${COMPUTE_ENV_NAME}" \
        --state DISABLED \
        --region "${AWS_REGION}" || log "Compute environment may already be disabled"
    
    log "Waiting for compute environment to be disabled (30 seconds)..."
    sleep 30
    
    # Verify no job queues reference this compute environment
    log "Verifying no job queues reference the compute environment..."
    local queues=$(aws batch describe-job-queues \
        --region "${AWS_REGION}" \
        --query "jobQueues[?computeEnvironmentOrder[?computeEnvironment=='arn:aws:batch:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):compute-environment/${COMPUTE_ENV_NAME}']].jobQueueName" \
        --output text 2>/dev/null || true)
    
    if [[ -n "$queues" ]]; then
        error "Cannot delete compute environment: still referenced by queues: ${queues}. Wait longer for queue deletion."
    fi
    
    log "Deleting compute environment: ${COMPUTE_ENV_NAME}"
    aws batch delete-compute-environment \
        --compute-environment "${COMPUTE_ENV_NAME}" \
        --region "${AWS_REGION}" || error "Failed to delete compute environment"
    
    log "Waiting for compute environment deletion to complete (30 seconds)..."
    sleep 30
else
    log "Compute environment doesn't exist, skipping"
fi

# Step 3: Get ECR registry
log "Step 3/5: Getting ECR registry URL"
ECR_REGISTRY=$(aws ecr describe-repositories \
    --repository-names osrm-process-data \
    --region "${AWS_REGION}" \
    --query 'repositories[0].repositoryUri' \
    --output text 2>/dev/null)

if [[ -z "$ECR_REGISTRY" ]]; then
    error "ECR repository 'osrm-process-data' not found. Run setup-aws-batch.sh create-ecr first."
fi

log "Using ECR registry: ${ECR_REGISTRY}"

# Step 4: Create new job definition
log "Step 4/5: Creating new job definition with updated configuration"
./setup-aws-batch.sh \
    -r "${ECR_REGISTRY}" \
    --region "${AWS_REGION}" \
    --ebs-size "${EBS_VOLUME_SIZE}" \
    create-job-def || error "Failed to create job definition"

# Step 5: Create new compute environment and queue
log "Step 5/5: Creating new compute environment and queue with ${EBS_VOLUME_SIZE}GB storage"
./setup-aws-batch.sh \
    --region "${AWS_REGION}" \
    --ebs-size "${EBS_VOLUME_SIZE}" \
    create-queue || error "Failed to create compute environment and queue"

log ""
log "✓ AWS Batch infrastructure recreation complete!"
log "✓ Compute environment: ${COMPUTE_ENV_NAME} (with ${EBS_VOLUME_SIZE}GB EBS volumes)"
log "✓ Job queue: ${QUEUE_NAME}"
log "✓ Job definition: ${JOB_DEFINITION_NAME}"
log ""
log "You can now submit jobs using ./submit-planet-job.sh"
