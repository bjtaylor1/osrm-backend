#!/bin/bash
set -e

# Build OSRM Docker image for AWS Batch (AMD64 architecture)

rm *.osm.pbf # in case any are left over from attempting to build one with them embedded

GIT_ROOT="$(git rev-parse --show-toplevel)"
cd "$GIT_ROOT"

docker buildx build \
  --platform linux/amd64 \
  -f ./aws-deployment/Dockerfile.split-osrm-data \
  -t osrm-split-data:latest \
  --load \
  .
