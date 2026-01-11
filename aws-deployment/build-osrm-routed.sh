#!/bin/bash
set -e

# Build OSRM routed binary in Docker image

GIT_ROOT="$(git rev-parse --show-toplevel)"
cd "$GIT_ROOT"

docker buildx build \
  --platform linux/amd64 \
  -f ./aws-deployment/Dockerfile.build-osrm-routed \
  -t build-osrm-routed:latest \
  --load \
  .
