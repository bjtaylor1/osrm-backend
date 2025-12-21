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

# Check if planet-latest.osm.pbf exists
if [ ! -f "planet-latest.osm.pbf" ]; then
    echo "❌ Error: planet-latest.osm.pbf not found in $SCRIPT_DIR"
    echo ""
    echo "Please download the planet file first:"
    echo "  wget https://planet.osm.org/pbf/planet-latest.osm.pbf"
    exit 1
fi

PLANET_FILE="planet-latest.osm.pbf"

# Check if SPLIT_CONFIG is set
if [ -z "${SPLIT_CONFIG:-}" ]; then
    echo "❌ Error: SPLIT_CONFIG environment variable not set"
    echo ""
    echo "Example usage:"
    echo "  SPLIT_CONFIG=s3://my-osrm-data-715/config/planet-slices.json ./run-split-test.sh"
    echo "  SPLIT_CONFIG=config/planet-slices.json ./run-split-test.sh"
    exit 1
fi

# Set default output directory if not specified
OSRM_OUTPUT_DIR="${OSRM_OUTPUT_DIR:-/output}"

echo "🚀 Starting OSRM split test..."
echo "   Planet file: $PLANET_FILE"
echo "   Split config: $SPLIT_CONFIG"
echo "   Output dir: $OSRM_OUTPUT_DIR"
echo ""

# Run the container
# Mount the current directory to /data so planet.osm.pbf is available
# Mount config directory if using local config
docker run --rm \
    -v "$SCRIPT_DIR:/data" \
    -v "$SCRIPT_DIR/output:/output" \
    -v "$SCRIPT_DIR/logs:/logs" \
    -e "SPLIT_CONFIG=$SPLIT_CONFIG" \
    -e "OSRM_OUTPUT_DIR=$OSRM_OUTPUT_DIR" \
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}" \
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}" \
    -e "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:-}" \
    -e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}" \
    osrm-split-test:latest

echo ""
echo "✅ Split test complete!"
echo ""
echo "Check the results in:"
echo "  - Output files: $SCRIPT_DIR/output/"
echo "  - Logs: $SCRIPT_DIR/logs/split-test.log"
