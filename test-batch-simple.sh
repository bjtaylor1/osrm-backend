#!/bin/bash
# Simple AWS Batch test - just run "hello world"

set -e

echo "=== Step 1: Testing AWS CLI access ==="
aws sts get-caller-identity

echo ""
echo "=== Step 2: Checking if we can describe Batch resources ==="
aws batch describe-compute-environments --region us-east-1 | head -20

echo ""
echo "=== Step 3: Checking ECR access ==="
aws ecr describe-repositories --region us-east-1 | head -20

echo ""
echo "=== Step 4: Checking EC2 (needed for Batch) ==="
aws ec2 describe-vpcs --region us-east-1 --query 'Vpcs[0].VpcId' --output text

echo ""
echo "=== All basic checks passed! ==="
echo ""
echo "Next: Let's use the AWS Console to create Batch resources manually,"
echo "then we can automate it once we know it works."
