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

env

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


# Download OSM file
cd /data
log_progress "Downloading ${OSM_SOURCE?}"
wget --no-verbose "${OSM_SOURCE?}"
wget --no-verbose "${OSM_SOURCE?}.md5"
md5sum -c "${OSM_FILE?}.osm.pbf.md5"

# Split
log_progress "Splitting ${OSM_FILE}.osm.pbf"

INPUT_FILE="/data/${OSM_FILE}.osm.pbf"
BASE_NAME="${INPUT_FILE%.osm.pbf}"
REGION_NAME=$(basename "$BASE_NAME")

# Find poly files for this region
POLY_FILES=(/src/aws-deployment/config/${REGION_NAME}.*.poly)

# If no poly files exist, skip splitting
if [[ ! -f "${POLY_FILES[0]}" ]]; then
    log_progress "No poly files found for ${REGION_NAME}, skipping split"
else
    log_progress "Found ${#POLY_FILES[@]} poly files for splitting"
    
    # Process each poly file
    for poly_file in "${POLY_FILES[@]}"; do
        NAME=$(basename "$poly_file" .poly)
        OUTPUT_FILE="/data/${NAME}.osm.pbf"
        
        log_progress "Extracting ${NAME} to /data"
        log_progress "using JAVACMD_OPTIONS: $JAVACMD_OPTIONS"
        
        osmosis --read-pbf "$INPUT_FILE" \
                --bounding-polygon file="$poly_file" \
                --write-pbf "$OUTPUT_FILE" \
                || handle_error "Failed to split ${NAME}"
        
        log_progress "Successfully split $NAME"
        aws s3 cp "$OUTPUT_FILE" "s3://my-osrm-data-715/output/${NAME}.osm.pbf"
        md5sum $OUTPUT_FILE
        log_progress "Successfully uploaded $NAME to S3"
        rm $OUTPUT_FILE
    done
fi