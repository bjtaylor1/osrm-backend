#!/bin/bash
set -e

# Push OSRM split image to AWS ECR

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/osrm-split"

aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

docker tag osrm-process-data:latest "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"
