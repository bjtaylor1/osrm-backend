#!/bin/bash
set -e

# Deploy osrm-routed: build binary and upload to S3

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🔨 Building osrm-routed binary..."
"$SCRIPT_DIR/build-osrm-routed.sh"

echo ""
echo "📤 Uploading osrm-routed to S3..."
"$SCRIPT_DIR/upload-osrm-routed.sh"
