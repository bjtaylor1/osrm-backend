#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

echo "Setting up AWS Batch resources in ${REGION}"

aws ecr describe-repositories --repository-names osrm-processor --region "${REGION}" &>/dev/null || \
aws ecr create-repository --repository-name osrm-processor --region "${REGION}" --image-scanning-configuration scanOnPush=true

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/osrm-processor"

aws iam get-role --role-name OSRMBatchExecutionRole &>/dev/null || \
aws iam create-role --role-name OSRMBatchExecutionRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": ["batch.amazonaws.com","ecs-tasks.amazonaws.com","ec2.amazonaws.com"]},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole || true
aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role || true
aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess || true

aws iam get-instance-profile --instance-profile-name OSRMBatchExecutionRole &>/dev/null || {
  echo "Creating instance profile..."
  aws iam create-instance-profile --instance-profile-name OSRMBatchExecutionRole
  aws iam add-role-to-instance-profile --instance-profile-name OSRMBatchExecutionRole --role-name OSRMBatchExecutionRole
  sleep 10
}

SUBNET_ID=$(aws ec2 describe-subnets --region "${REGION}" --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" --filters Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text)
INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name OSRMBatchExecutionRole --query 'InstanceProfile.Arn' --output text)

echo "Using subnet ${SUBNET_ID} and security group ${SG_ID}"

aws ec2 describe-launch-templates --region "${REGION}" --launch-template-names osrm-processor-launch-template &>/dev/null || \
aws ec2 create-launch-template --region "${REGION}" --launch-template-name osrm-processor-launch-template --launch-template-data '{
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {"VolumeSize": 500, "VolumeType": "gp3", "DeleteOnTermination": true}
  }]
}'

LAUNCH_TEMPLATE_ID=$(aws ec2 describe-launch-templates --region "${REGION}" --launch-template-names osrm-processor-launch-template --query 'LaunchTemplates[0].LaunchTemplateId' --output text)

aws batch describe-compute-environments --region "${REGION}" --compute-environments osrm-processor-compute-env &>/dev/null || {
  echo "Creating compute environment..."
  aws batch create-compute-environment \
    --region "${REGION}" \
    --compute-environment-name osrm-processor-compute-env \
    --type MANAGED \
    --state ENABLED \
    --compute-resources type=EC2,minvCpus=0,maxvCpus=256,desiredvCpus=0,instanceTypes=m5.large,instanceRole="${INSTANCE_PROFILE_ARN}",subnets="${SUBNET_ID}",securityGroupIds="${SG_ID}",launchTemplate="{launchTemplateId=${LAUNCH_TEMPLATE_ID}}"
}

echo "Waiting for compute environment..."
for i in {1..60}; do
  STATUS=$(aws batch describe-compute-environments --region "${REGION}" --compute-environments osrm-processor-compute-env --query 'computeEnvironments[0].status' --output text 2>/dev/null || echo "NOTFOUND")
  [[ "$STATUS" == "VALID" ]] && break
  sleep 2
done
echo "Compute environment status: ${STATUS}"

if [[ "$STATUS" != "VALID" ]]; then
  echo "ERROR: Compute environment did not become VALID"
  exit 1
fi

echo "Creating job queue..."
QUEUE_EXISTS=$(aws batch describe-job-queues --region "${REGION}" --job-queues osrm-processor-queue --query 'length(jobQueues)' --output text 2>/dev/null || echo "0")
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

echo "Registering job definition..."
aws batch register-job-definition \
  --region "${REGION}" \
  --job-definition-name osrm-processor-job \
  --type container \
  --platform-capabilities EC2 \
  --container-properties "{
    \"image\": \"${ECR_URI}:latest\",
    \"vcpus\": 4,
    \"memory\": 8192,
    \"executionRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"jobRoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/OSRMBatchExecutionRole\",
    \"ulimits\": [{\"name\": \"nofile\", \"hardLimit\": 65536, \"softLimit\": 65536}]
  }" \
  --retry-strategy attempts=3 \
  --timeout attemptDurationSeconds=7200

echo "Setup complete"