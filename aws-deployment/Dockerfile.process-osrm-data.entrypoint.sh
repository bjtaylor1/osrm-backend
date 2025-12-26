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

# Process each split file
poly_files=("/src/config/$OSM_FILE".*.poly)

# Check if any files were found
if [ ${#poly_files[@]} -eq 0 ]; then
    handle_error "No .poly files found matching pattern: /src/config/$OSM_FILE.*.poly"
fi

log_progress "Found ${#poly_files[@]} split file(s) to process"

for split_file in "${poly_files[@]}"; do
    file_name=$(basename "$split_file" .poly)
    # e.g. monaco-latest.a

    pbf_file="${file_name}.osm.pbf"
    #e.g. monaco-latest.a.osm.pbf

    aws s3 cp --no-progress "s3://my-osrm-data-715/output/$pbf_file" "$pbf_file"
    osrm-extract \
        "$pbf_file" \
        --profile "/src/profiles/${PROFILE?}.lua" \
        --threads "$(nproc)" \
        ${EXTRACT_EXTRA_ARGS:-}
    
    log_progress "Contracting ${file_name}"
    osrm-contract \
        "${file_name}.osrm" \
        --threads "$(nproc)" \
        ${CONTRACT_EXTRA_ARGS:-}
    
    log_progress "Uploading ${file_name}"
    for file in "${file_name}".osrm*; do
        aws s3 cp --no-progress "$file" "s3://my-osrm-data/output/$(basename "$file")"
    done
done
