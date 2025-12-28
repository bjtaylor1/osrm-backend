#!/bin/bash
set -e

# Build OSRM Docker image for AWS Batch (AMD64 architecture)

GIT_ROOT="$(git rev-parse --show-toplevel)"
cd "$GIT_ROOT"

ln ~/monaco-latest.osm.pbf
ln ~/planet-latest.osm.pbf
# has to be within source dir

docker buildx build \
  --platform linux/amd64 \
  -f ./aws-deployment/Dockerfile.process-direct-osrm-data \
  -t osrm-process-direct-data:latest \
  --load \
  .
rm monaco-latest.osm.pbf
rm planet-latest.osm.pbf
