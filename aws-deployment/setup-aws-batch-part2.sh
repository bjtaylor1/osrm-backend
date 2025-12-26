#!/bin/bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-east-1")

echo "Setting up AWS Batch resources (Part 2) in ${REGION}"

echo "Checking compute environment status..."
STATUS=$(aws batch describe-compute-environments --region "${REGION}" --compute-environments osrm-processor-compute-env --query 'computeEnvironments[0].status' --output text || echo "NOTFOUND")
echo "Compute environment status: ${STATUS}"

if [[ "$STATUS" != "VALID" ]]; then
  echo ""
  echo "ERROR: Compute environment 'osrm-processor-compute-env' is not VALID (status: ${STATUS})"
  echo "Wait for it to become VALID before running this script."
  echo "Check status with:"
  echo "  aws batch describe-compute-environments --region ${REGION} --compute-environments osrm-processor-compute-env --query 'computeEnvironments[0].status'"
  exit 1
fi

ECR_URI_PROCESS="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/osrm-processor"
ECR_URI_SPLIT="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/osrm-split"

echo "Creating job queue..."
QUEUE_EXISTS=$(aws batch describe-job-queues --region "${REGION}" --job-queues osrm-processor-queue --query 'length(jobQueues)' --output text || echo "0")
if [[ "$QUEUE_EXISTS" == "0" ]]; then
  aws batch create-job-queue \
    --region "${REGION}" \
    --job-queue-name osrm-processor-queue \
    --state ENABLED \
    --priority 1 \
    --compute-environment-order order=1,computeEnvironment=osrm-processor-compute-env
else
  echo "Job queue already exists"
fi

echo "Registering job definitions..."
aws batch register-job-definition \
  --region "${REGION}" \
  --job-definition-name osrm-processor-job \
  --type container \
  --platform-capabilities EC2 \
  --container-properties "{
    \"image\": \"${ECR_URI_PROCESS}:latest\",
    \"vcpus\": 2,
    \"memory\": 8192,
    \"executionRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"jobRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"ulimits\": [{\"name\": \"nofile\", \"hardLimit\": 65536, \"softLimit\": 65536}]
  }" \
  --retry-strategy attempts=3 \
  --timeout attemptDurationSeconds=86400

aws batch register-job-definition \
  --region "${REGION}" \
  --job-definition-name osrm-split-job \
  --type container \
  --platform-capabilities EC2 \
  --container-properties "{
    \"image\": \"${ECR_URI_SPLIT}:latest\",
    \"vcpus\": 2,
    \"memory\": 8192,
    \"executionRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"jobRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"ulimits\": [{\"name\": \"nofile\", \"hardLimit\": 65536, \"softLimit\": 65536}]
  }" \
  --retry-strategy attempts=3 \
  --timeout attemptDurationSeconds=86400

echo "Setup complete"
