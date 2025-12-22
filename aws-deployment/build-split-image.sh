#!/bin/bash
# Build the split testing Docker image

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

echo "Building OSRM split testing image..."
docker build -f Dockerfile.test-planet-split -t osrm-split-test:latest .

echo ""
echo "✅ Build complete!"
echo ""
echo "Image: osrm-split-test:latest"
echo ""
echo "To run the split test, use:"
echo "  ./run-split-test.sh"
