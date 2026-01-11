#!/bin/bash
ROUTER_AMI=ami-041dd32aca9f76437
#DEBIAN12_AMI=ami-08841d8c15f47fb42
SCRIPT_DIR=$(dirname "$0")

export AWS_PAGER=""

# Default router region if not specified
ROUTER_REGION=${ROUTER_REGION:-planet-latest}
INSTANCE_NAME="Router$(date +%Y%m%d)"
if [ "$ROUTER_REGION" = "planet-latest" ]; then
    INSTANCE_TYPE=i3.large
    SWAP_SPACE=102400 # 100GB
else
    INSTANCE_TYPE=t3.micro
    SWAP_SPACE=1024 # 1GB (it's only got 8GB in total)
fi
# swap space is in MB (a small instance can't do 1GB blocks)

echo "Deploying a $INSTANCE_TYPE instance for router region $ROUTER_REGION"

aws ec2 run-instances \
    --image-id $ROUTER_AMI \
    --instance-type $INSTANCE_TYPE \
    --iam-instance-profile Name=OSRM-Instance-Profile \
    --key-name gpxeditor_useast1 \
    --region us-east-1 \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=router-region,Value=${ROUTER_REGION}},{Key=swap-space,Value=${SWAP_SPACE}}]" \
    --user-data "file://${SCRIPT_DIR}/deploy-server.startup-script.sh"