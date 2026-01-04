#!/bin/bash
# Run the split testing Docker image
# 
# Prerequisites:
# 1. planet-latest.osm.pbf must be in the current directory (aws-deployment/)
# 2. SPLIT_CONFIG environment variable must point to your config (S3 or local path)
# 
# Example usage:
#   SPLIT_CONFIG=s3://my-osrm-data-715/config/planet-slices.json ./run-split-test.sh
#   SPLIT_CONFIG=config/planet-slices.json ./run-split-test.sh

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"
awsdir="$HOME/.aws"

echo "🚀 Starting process OSRM data..."

rm -rf "$SCRIPT_DIR/data"
mkdir -p "$SCRIPT_DIR/data"
touch "$SCRIPT_DIR/data/nomount.flag" # tells it not to mount the bigdisk


# Run the container
docker run --rm --platform linux/amd64 \
    -v "$SCRIPT_DIR/output:/output:rw" \
    -v "$SCRIPT_DIR/logs:/logs:rw" \
    -v "$SCRIPT_DIR/data:/data:rw" \
    -v "$awsdir:/root/.aws:ro" \
    -e "BASE_NAME=nottinghamshireandlincolnshire" \
    -e "AWS_DEFAULT_REGION=us-east-1" \
    -e "AWS_PROFILE=gpxeditoradmin" \
    -e "PROFILE=bicycle_paved" \
    osrm-process-data:latest

echo ""
echo "✅ Process OSRM data finished!"
echo ""
echo "Check the results in:"
echo "  - Output files: $SCRIPT_DIR/output/"
echo "  - Logs: $SCRIPT_DIR/logs/split-test.log"
