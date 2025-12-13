# Quick Start Testing Guide

## Prerequisites Setup

### 1. AWS Resources You Need

```bash
# Set your AWS region
export AWS_DEFAULT_REGION=us-east-1

# Create S3 bucket
aws s3 mb s3://osrm-test-$(date +%s)
# Note the bucket name for later

# Create IAM role for EC2 instances (if not exists)
aws iam create-role \
    --role-name OSRM-EC2-Role \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "ec2.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }'

# Attach S3 read policy
aws iam attach-role-policy \
    --role-name OSRM-EC2-Role \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

# Create instance profile
aws iam create-instance-profile --instance-profile-name OSRM-EC2-Role
aws iam add-role-to-instance-profile \
    --instance-profile-name OSRM-EC2-Role \
    --role-name OSRM-EC2-Role

# Create security group
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name osrm-test-sg \
    --description "OSRM test security group" \
    --query 'GroupId' \
    --output text)

# Allow SSH from your IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 22 \
    --cidr ${MY_IP}/32

# Allow HTTP from anywhere (for OSRM API)
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

echo "Security Group ID: $SECURITY_GROUP_ID"

# Create or use existing EC2 key pair
# If you don't have one:
aws ec2 create-key-pair \
    --key-name osrm-test-key \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/osrm-test-key.pem
chmod 400 ~/.ssh/osrm-test-key.pem
```

### 2. Environment Variables

```bash
# Required for all steps
export S3_BUCKET=osrm-test-1234567890  # Use your bucket name
export AWS_DEFAULT_REGION=us-east-1
export KEY_NAME=osrm-test-key
export SECURITY_GROUP=sg-xxxxxxxxxxxxx  # Your security group ID

# Optional - for AWS Batch
export JOB_QUEUE=osrm-batch-queue
export JOB_DEFINITION=osrm-batch-job
```

## Testing Steps

### Step 1: Build Docker Image (One-time setup)

```bash
cd /Users/bentaylor/osrm-backend

# Build the Docker image
docker build -f Dockerfile.aws-batch -t osrm-aws-batch:test .

# This takes ~30-45 minutes (compiles OSRM)
# You can continue while it builds in background
```

### Step 2: Test Docker Container Locally (Optional)

This step is optional - you can skip directly to Step 3 to test on AWS Batch.

If you want to test the Docker image locally first:

```bash
# Create test directory
mkdir -p /tmp/osrm-test
cd /tmp/osrm-test

# Download Monaco (tiny dataset, ~1 MB)
wget http://download.geofabrik.de/europe/monaco-latest.osm.pbf

# Test the Docker container locally
docker run --rm \
    -v /tmp/osrm-test:/data \
    -e OSRM_OPERATION=extract \
    -e OSM_FILE=/data/monaco-latest.osm.pbf \
    -e PROFILE=bicycle_paved \
    -e OSRM_DATA_DIR=/data \
    -e OSRM_OUTPUT_DIR=/data \
    osrm-aws-batch:test

# Should create monaco.osrm and related files
ls -lh /tmp/osrm-test/

# Test routing server
docker run --rm -p 5000:5000 \
    -v /tmp/osrm-test:/data \
    -e OSRM_OPERATION=routed \
    -e OSRM_FILE=/data/monaco.osrm \
    -e OSRM_DATA_DIR=/data \
    osrm-aws-batch:test &

# Test API (Monaco coordinates)
sleep 10
curl "http://localhost:5000/route/v1/bicycle/7.416,43.731;7.421,43.736?steps=true"

# Should return JSON with route
# Kill the server: docker stop $(docker ps -q --filter ancestor=osrm-aws-batch:test)
```

### Step 3: Push to ECR and Setup AWS Batch (if using batch processing)

```bash
cd /Users/bentaylor/osrm-backend

# Setup AWS Batch infrastructure
./setup-aws-batch.sh setup-full \
    --region us-east-1

# This will:
# 1. Create ECR repository
# 2. Push Docker image
# 3. Create batch job definition
# 4. Create compute environment and job queue
```

### Step 4: Test Complete Workflow in AWS Batch (Recommended)

This tests everything running in the cloud - no local processing:

```bash
cd /Users/bentaylor/osrm-backend/aws-deployment/scripts

# Run complete test with small regions
./process-osrm-batch.sh \
    --s3-bucket ${S3_BUCKET} \
    --mode test

# This will:
# 1. Submit 6 extract jobs (Monaco, Liechtenstein, etc.)
# 2. Wait for all to complete
# 3. Submit 6 contract jobs
# 4. Wait for all to complete
# 5. Verify files in S3
#
# Takes ~15 minutes, costs ~$0.50

# Monitor progress - the script shows all job IDs
# Or check in AWS Console: Batch > Jobs

# Verify output
aws s3 ls s3://${S3_BUCKET}/processed/
```

### Step 5: Test EC2 Deployment with Monaco Data

```bash
cd /Users/bentaylor/osrm-backend/aws-deployment/scripts

# First, manually upload Monaco processed data
aws s3 cp /tmp/osrm-test/monaco.osrm s3://${S3_BUCKET}/processed/slice_a_north_america.osrm
aws s3 cp /tmp/osrm-test/monaco.osrm.* s3://${S3_BUCKET}/processed/

# For testing, create dummy files for other slices (or modify deploy script)
for slice in b c d e f; do
    aws s3 cp /tmp/osrm-test/monaco.osrm \
        s3://${S3_BUCKET}/processed/slice_${slice}_*.osrm
done

# Deploy test server
./deploy-server.sh \
    --s3-bucket ${S3_BUCKET} \
    --instance-type t3.medium \
    --key-name ${KEY_NAME} \
    --security-group ${SECURITY_GROUP}

# Note the instance IP from output
# Wait 15-20 minutes for setup

# Monitor progress
ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@<instance-ip> \
    'tail -f /var/log/cloud-init-output.log'

# Test the API
curl "http://<instance-ip>/health"
curl "http://<instance-ip>/route/v1/bicycle/7.416,43.731;7.421,43.736"
```

## Quick Sanity Checks

```bash
# 1. Docker image exists
docker images | grep osrm-aws-batch

# 2. ECR repository exists
aws ecr describe-repositories --repository-names osrm-aws-batch

# 3. S3 bucket accessible
aws s3 ls s3://${S3_BUCKET}/

# 4. Batch job definition exists
aws batch describe-job-definitions --job-definition-name osrm-batch-job

# 5. Compute environment ready
aws batch describe-compute-environments

# 6. Job queue active
aws batch describe-job-queues
```

## Common Issues

### Docker Build Fails
```bash
# Check Docker is running
docker info

# Increase Docker memory to 8GB in Docker Desktop settings
# Retry build
```

### AWS Batch Job Fails
```bash
# Get job logs
aws batch describe-jobs --jobs <job-id>

# Check CloudWatch logs
aws logs get-log-events \
    --log-group-name /aws/batch/job \
    --log-stream-name <stream-name>
```

### EC2 Instance Not Starting Services
```bash
# SSH in and check
ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@<ip>

# Check cloud-init logs
sudo tail -f /var/log/cloud-init-output.log

# Check supervisor
sudo supervisorctl status

# Check nginx
sudo systemctl status nginx
```

## Clean Up Test Resources

```bash
# Terminate EC2 instances
aws ec2 terminate-instances --instance-ids <instance-id>

# Delete S3 bucket
aws s3 rb s3://${S3_BUCKET} --force

# Delete security group
aws ec2 delete-security-group --group-id ${SECURITY_GROUP}

# Delete batch resources
aws batch update-job-queue \
    --job-queue osrm-batch-queue \
    --state DISABLED
aws batch delete-job-queue --job-queue osrm-batch-queue
aws batch update-compute-environment \
    --compute-environment osrm-batch-compute-env \
    --state DISABLED
aws batch delete-compute-environment \
    --compute-environment osrm-batch-compute-env

# Delete ECR repository
aws ecr delete-repository \
    --repository-name osrm-aws-batch \
    --force
```

## Next Steps for Production

Once testing works:
1. Use full planet file instead of Monaco
2. Run actual geographic slicing
3. Deploy production-sized instance (i3.xlarge)
4. Setup monitoring and backups
