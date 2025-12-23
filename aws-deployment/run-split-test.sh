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

echo "🚀 Starting OSRM split test..."

# Run the container
# Mount the current directory to /data so planet.osm.pbf is available
# Mount config directory if using local config
awsdir=$(cd ~/.aws && pwd)
docker run --rm \
    -v "$SCRIPT_DIR:/data:ro" \
    -v "$SCRIPT_DIR/output:/output:rw" \
    -v "$SCRIPT_DIR/logs:/logs:rw" \
    -v "${awsdir}:/root/.aws:ro" \
    -e "AWS_DEFAULT_REGION=us-east-1" \
    -e "AWS_PROFILE=gpxeditoradmin" \
    osrm-split-test:latest

echo ""
echo "✅ Split test complete!"
echo ""
echo "Check the results in:"
echo "  - Output files: $SCRIPT_DIR/output/"
echo "  - Logs: $SCRIPT_DIR/logs/split-test.log"
