#!/bin/bash
# Build the split testing Docker image

set -e

GIT_ROOT="$(git rev-parse --show-toplevel)"
cd "$GIT_ROOT"

echo "Building OSRM split testing image..."
docker build -f aws-deployment/Dockerfile.test-planet-split -t osrm-split-test:latest .

echo ""
echo "✅ Build complete!"
echo ""
echo "Image: osrm-split-test:latest"
echo ""
echo "To run the split test, use:"
echo "  ./run-split-test.sh"
