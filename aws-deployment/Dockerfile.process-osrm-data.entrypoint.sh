#!/bin/bash
set -euo pipefail

trap 'echo "$(date "+%Y-%m-%d %H:%M:%S") - FATAL ERROR at line $LINENO: Command failed with exit code $?" >&2' ERR

exec > >(tee -a /logs/process-osrm-data.log) 2>&1

handle_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2
    exit 1
}

log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_progress "Processing OSRM data"

if [ ! -f "/data/nomount.flag" ]; then 
    echo "nomount.flag doesn't exist"
    lsblk
    # setup big disk and swap space (if not running locally):
    INSTANCE_STORE_DEV=$(lsblk -d -n -o NAME,MOUNTPOINT | grep nvme | grep -v '/$' | head -1 | awk '{print $1}')
    if [[ -n "$INSTANCE_STORE_DEV" ]]; then
        log_progress "Formatting instance store $INSTANCE_STORE_DEV"
        mkfs /dev/$INSTANCE_STORE_DEV
        mount /dev/$INSTANCE_STORE_DEV /data

        log_progress "Creating swap space"
        dd if=/dev/zero of=/data/swapfile bs=1G count=50
        chmod 600 /data/swapfile
        mkswap /data/swapfile
        swapon /data/swapfile

        df -h

    else
        lsblk
        handle_error "Instance store not found - exiting. We need the instance store to process the large amount of data"
    fi
else
    log_progress "nomount.flag exists (must be running locally)"
fi

cd /data

# Enable nullglob so non-matching patterns expand to nothing instead of literal string
shopt -s nullglob

pbf_file="${BASE_NAME?}.osm.pbf"
#e.g. monaco-latest.a

aws s3 cp --no-progress "s3://my-osrm-data-715/output/${pbf_file}" "$pbf_file"
log_progress "Extracting ${BASE_NAME?}"
osrm-extract \
    "$pbf_file" \
    --profile "/src/profiles/${PROFILE?}.lua" \
    --threads "$(nproc)" \
    ${EXTRACT_EXTRA_ARGS:-} || handle_error "osrm-extract failed"

log_progress "Contracting ${BASE_NAME?}"
osrm-contract \
    "${BASE_NAME}.osrm" \
    --threads "$(nproc)" \
    ${CONTRACT_EXTRA_ARGS:-} || handle_error "osrm-contract failed"

log_progress "Uploading ${BASE_NAME?} output files..."
for file in "${BASE_NAME}".osrm*; do
    aws s3 cp --no-progress "$file" "s3://my-osrm-data-715/output/$(basename "$file")"
done
log_progress "Finished processing ${BASE_NAME?}"