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
homedir="$HOME"
awsdir="$HOME/.aws"
inputfile="$homedir/planet-latest.osm.pbf"

# Check if planet-latest.osm.pbf exists
if [ ! -f "$inputfile" ]; then
    echo "❌ Error: $inputfile not found"
    echo ""
    echo "Please download the planet file first:"
    echo "  wget https://planet.osm.org/pbf/planet-latest.osm.pbf"
    exit 1
fi

echo "🚀 Starting OSRM split test..."

# Run the container
# Mount planet file as read-only, output and logs as writable
docker run --rm \
    -v "$SCRIPT_DIR/output:/output:rw" \
    -v "$SCRIPT_DIR/logs:/logs:rw" \
    -v "$inputfile:/data/planet-latest.osm.pbf:ro" \
    -v "$awsdir:/root/.aws:ro" \
    -e "AWS_DEFAULT_REGION=us-east-1" \
    -e "AWS_PROFILE=gpxeditoradmin" \
    osrm-split-test:latest

echo ""
echo "✅ Split test complete!"
echo ""
echo "Check the results in:"
echo "  - Output files: $SCRIPT_DIR/output/"
echo "  - Logs: $SCRIPT_DIR/logs/split-test.log"
