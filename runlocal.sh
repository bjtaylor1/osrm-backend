#!/usr/bin/env bash
set -e

# 1. Build
docker build -t osrm-backend-local -f docker/Dockerfile-debian .

# 2. Extract
docker run --rm -t \
  -v "$PWD/aws-deployment/data:/data" \
  osrm-backend-local \
  osrm-extract --threads 2 -p /opt/bicycle_paved.lua /data/data.osm.pbf

# 3. Contract
docker run --rm -t \
  -v "$PWD/aws-deployment/data:/data" \
  osrm-backend-local \
  osrm-contract --threads 2 /data/data.osrm

# 4. Run
docker run --rm -t \
  -p 127.0.0.1:5001:5001 \
  -v "$PWD/aws-deployment/data:/data:ro" \
  osrm-backend-local \
  osrm-routed --algorithm ch /data/data.osrm -p 5001
