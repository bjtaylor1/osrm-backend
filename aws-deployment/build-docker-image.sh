#!/bin/bash
set -e

# Build OSRM Docker image for AWS Batch (AMD64 architecture)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${PROJECT_ROOT}"

docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile.aws-batch \
  -t osrm-aws-batch:latest \
  --load \
  .
