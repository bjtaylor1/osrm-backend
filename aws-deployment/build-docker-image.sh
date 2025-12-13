#!/bin/bash
set -e

# Build OSRM Docker image for AWS Batch (AMD64 architecture)

docker buildx build \
  --platform linux/amd64 \
  -f ./aws-deployment/Dockerfile.aws-batch \
  -t osrm-aws-batch:latest \
  --load \
  .
