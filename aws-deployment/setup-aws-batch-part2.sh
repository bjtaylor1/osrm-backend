#!/bin/bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-east-1")

echo "Setting up AWS Batch resources (Part 2) in ${REGION}"

echo "Checking compute environment status..."
STATUS=$(aws batch describe-compute-environments --region "${REGION}" --compute-environments compute-env-i3-large --query 'computeEnvironments[0].status' --output text || echo "NOTFOUND")
echo "Compute environment status: ${STATUS}"

if [[ "$STATUS" != "VALID" ]]; then
  echo ""
  echo "ERROR: Compute environment 'compute-env-i3-large' is not VALID (status: ${STATUS})"
  echo "Wait for it to become VALID before running this script."
  echo "Check status with:"
  echo "  aws batch describe-compute-environments --region ${REGION} --compute-environments compute-env-i3large --query 'computeEnvironments[0].status'"
  exit 1
fi

ECR_URI_PROCESS="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/osrm-processor"
ECR_URI_DIRECT_PROCESS="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/osrm-direct-processor"
ECR_URI_SPLIT="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/osrm-split"

for instance_type in i3.large i3.xlarge r6g.medium r5d.16xlarge; do
  job_queue_to_create="job-queue-${instance_type//./-}"
  compute_env="compute-env-${instance_type//./-}"

  echo "Creating job queue..."
  QUEUE_EXISTS=$(aws batch describe-job-queues --region "${REGION}" --job-queues $job_queue_to_create --query 'length(jobQueues)' --output text || echo "0")
  if [[ "$QUEUE_EXISTS" == "0" ]]; then
    aws batch create-job-queue \
      --region "${REGION}" \
      --job-queue-name $job_queue_to_create \
      --state ENABLED \
      --priority 1 \
      --compute-environment-order order=1,computeEnvironment=$compute_env
  else
    echo "Job queue $job_queue_to_create already exists"
  fi
done

echo "Registering job definitions..."
aws batch register-job-definition \
  --region "${REGION}" \
  --job-definition-name osrm-processor-job \
  --type container \
  --platform-capabilities EC2 \
  --container-properties "{
    \"image\": \"${ECR_URI_PROCESS}:latest\",
    \"vcpus\": 64,
    \"memory\": 500000,
    \"privileged\": true,
    \"executionRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"jobRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"ulimits\": [{\"name\": \"nofile\", \"hardLimit\": 65536, \"softLimit\": 65536}]
  }" \
  --retry-strategy attempts=3 \
  --timeout attemptDurationSeconds=86400

aws batch register-job-definition \
  --region "${REGION}" \
  --job-definition-name osrm-direct-processor-job \
  --type container \
  --platform-capabilities EC2 \
  --container-properties "{
    \"image\": \"${ECR_URI_DIRECT_PROCESS}:latest\",
    \"vcpus\": 64,
    \"memory\": 500000,
    \"privileged\": true,
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
    \"vcpus\": 4,
    \"memory\": 15250,
    \"privileged\": true,
    \"executionRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"jobRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"ulimits\": [{\"name\": \"nofile\", \"hardLimit\": 65536, \"softLimit\": 65536}]
  }" \
  --retry-strategy attempts=3 \
  --timeout attemptDurationSeconds=86400

echo "Setup complete"
