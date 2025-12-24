#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-east-1")

echo "Setting up AWS Batch resources (Part 1) in ${REGION}"

if aws ecr describe-repositories --repository-names osrm-processor --region "${REGION}" --query 'repositories[0].repositoryName' --output text; then
  echo "ECR repository already exists"
else
  aws ecr create-repository --repository-name osrm-processor --region "${REGION}" --image-scanning-configuration scanOnPush=true
fi

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/osrm-processor"

if aws iam get-role --role-name OSRMBatchExecutionRole --query 'Role.RoleName' --output text; then
  echo "IAM role already exists"
else
  aws iam create-role --role-name OSRMBatchExecutionRole --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": ["batch.amazonaws.com","ecs-tasks.amazonaws.com","ec2.amazonaws.com"]},
    "Action": "sts:AssumeRole"
  }]
}'
fi

aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole || true
aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role || true
aws iam attach-role-policy --role-name OSRMBatchExecutionRole --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess || true

if aws iam get-instance-profile --instance-profile-name OSRMBatchExecutionRole --query 'InstanceProfile.InstanceProfileName' --output text; then
  echo "Instance profile already exists"
else
  echo "Creating instance profile..."
  aws iam create-instance-profile --instance-profile-name OSRMBatchExecutionRole
  aws iam add-role-to-instance-profile --instance-profile-name OSRMBatchExecutionRole --role-name OSRMBatchExecutionRole
  sleep 10
fi

SUBNET_ID=$(aws ec2 describe-subnets --region "${REGION}" --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" --filters Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text)
INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name OSRMBatchExecutionRole --query 'InstanceProfile.Arn' --output text)

echo "Using subnet ${SUBNET_ID} and security group ${SG_ID}"

if aws ec2 describe-launch-templates --region "${REGION}" --launch-template-names osrm-processor-launch-template --query 'LaunchTemplates[0].LaunchTemplateName' --output text; then
  echo "Launch template already exists"
else
  aws ec2 create-launch-template --region "${REGION}" --launch-template-name osrm-processor-launch-template --launch-template-data '{
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {"VolumeSize": 500, "VolumeType": "gp3", "DeleteOnTermination": true}
  }]
}'
fi

LAUNCH_TEMPLATE_ID=$(aws ec2 describe-launch-templates --region "${REGION}" --launch-template-names osrm-processor-launch-template --query 'LaunchTemplates[0].LaunchTemplateId' --output text)

COMPUTE_ENV_NAME=$(aws batch describe-compute-environments --region "${REGION}" --compute-environments osrm-processor-compute-env --query 'computeEnvironments[0].computeEnvironmentName' --output text)
echo "Compute env check returned: '${COMPUTE_ENV_NAME}'"

if [[ "${COMPUTE_ENV_NAME}" == "osrm-processor-compute-env" ]]; then
  echo "Compute environment already exists"
else
  echo "Creating compute environment..."
  aws batch create-compute-environment \
    --region "${REGION}" \
    --compute-environment-name osrm-processor-compute-env \
    --type MANAGED \
    --state ENABLED \
    --compute-resources type=EC2,minvCpus=0,maxvCpus=256,desiredvCpus=0,instanceTypes=m5.large,instanceRole="${INSTANCE_PROFILE_ARN}",subnets="${SUBNET_ID}",securityGroupIds="${SG_ID}",launchTemplate="{launchTemplateId=${LAUNCH_TEMPLATE_ID}}"
fi

echo ""
echo "Part 1 complete. The compute environment is being created."
echo "Check its status in the AWS Console or run:"
echo "  aws batch describe-compute-environments --region ${REGION} --compute-environments osrm-processor-compute-env --query 'computeEnvironments[0].status'"
echo ""
echo "Once the status is 'VALID', run: ./setup-aws-batch-part2.sh"
