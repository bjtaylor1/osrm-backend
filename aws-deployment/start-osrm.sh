#!/bin/bash
# Startup script for OSRM production server

set -euo pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Download data from S3 if not present
if [[ -n "${S3_BUCKET:-}" ]] && [[ ! -f /opt/osrm/data/.downloaded ]]; then
    log "Downloading OSRM data from S3..."
    aws s3 sync "s3://${S3_BUCKET}/processed/" /opt/osrm/data/
    touch /opt/osrm/data/.downloaded
    log "Data download complete"
fi

# Verify data files exist
log "Verifying OSRM data files..."
for slice in slice_a_north_america slice_b_south_america slice_c_europe_africa slice_d_africa slice_e_asia slice_f_oceania; do
    if [[ ! -f "/opt/osrm/data/${slice}.osrm" ]]; then
        log "ERROR: Missing data file: ${slice}.osrm"
        exit 1
    fi
    log "Found: ${slice}.osrm"
done

# Start supervisor to manage OSRM processes
log "Starting supervisor..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf

# Wait for OSRM processes to start
log "Waiting for OSRM processes to initialize..."
sleep 10

# Start nginx
log "Starting nginx..."
nginx -g 'daemon off;' &

# Keep container running and monitor processes
log "OSRM server is running"
log "Monitoring processes..."

while true; do
    # Check if supervisor is running
    if ! pgrep supervisord > /dev/null; then
        log "ERROR: supervisord stopped"
        exit 1
    fi
    
    # Check if nginx is running
    if ! pgrep nginx > /dev/null; then
        log "ERROR: nginx stopped"
        exit 1
    fi
    
    sleep 30
done