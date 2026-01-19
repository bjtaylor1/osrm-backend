#!/bin/bash

# Setup script for creating the static security group for OSRM instances
# This should be run once before deploying any instances

set -e

REGION="us-east-1"
SG_NAME="allow-http-from-load-balancer"
SG_DESCRIPTION="Allow HTTP traffic from load balancer to OSRM instances"

# Get the default VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
    echo "Error: No default VPC found in region $REGION"
    exit 1
fi

echo "Using VPC: $VPC_ID"

# Check if security group already exists
EXISTING_SG=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
    echo "Security group '$SG_NAME' already exists with ID: $EXISTING_SG"
    exit 0
fi

# Create the security group
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --description "$SG_DESCRIPTION" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)

echo "Created security group: $SG_ID"

# Get the load balancer's security group ID
# First get the target group to find the load balancer
TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:us-east-1:259514351789:targetgroup/RouterTargetGroup/3e36e81cc0d20dfe"

LB_ARN=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --target-group-arns "$TARGET_GROUP_ARN" \
    --query 'TargetGroups[0].LoadBalancerArns[0]' \
    --output text)

LB_SG_ID=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --load-balancer-arns "$LB_ARN" \
    --query 'LoadBalancers[0].SecurityGroups[0]' \
    --output text)

echo "Load balancer security group: $LB_SG_ID"

# Add ingress rule to allow HTTP from load balancer
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --ip-permissions \
    "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$LB_SG_ID}]"

echo "Added ingress rule: Allow TCP port 80 from load balancer security group"
echo ""
echo "Security group '$SG_NAME' (ID: $SG_ID) is ready to use!"
