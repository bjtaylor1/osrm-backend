#!/bin/bash
ROUTER_AMI=ami-00932b450f2b640d8
#DEBIAN12_AMI=ami-08841d8c15f47fb42
SCRIPT_DIR=$(dirname "$0")

AWS_PAGER=""

# Default router region if not specified
ROUTER_REGION=${ROUTER_REGION:-planet-latest}
if [ "$ROUTER_REGION" = "planet-latest" ]; then
    INSTANCE_TYPE=i3.large
    SWAP_SPACE=100
else
    INSTANCE_TYPE=t3.micro
    SWAP_SPACE=10
fi

echo "Deploying a $INSTANCE_TYPE instance for router region $ROUTER_REGION"

aws ec2 run-instances \
    --image-id $ROUTER_AMI \
    --instance-type $INSTANCE_TYPE \
    --iam-instance-profile Name=OSRM-Instance-Profile \
    --key-name gpxeditor_useast1 \
    --region us-east-1 \
    --tag-specifications "ResourceType=instance,Tags=[{Key=router-region,Value=${ROUTER_REGION}},{Key=swap-space,Value=${SWAP_SPACE}}]" \
    --user-data "file://${SCRIPT_DIR}/deploy-server.startup-script.sh"