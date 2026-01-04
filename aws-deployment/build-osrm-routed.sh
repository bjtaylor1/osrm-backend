#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"
awsdir="$HOME/.aws"

docker run --rm --platform linux/amd64 \
    -v "$awsdir:/root/.aws:ro" \
    build-osrm-routed:latest

echo ""
echo "✅ Build osrm-routed finished!"
