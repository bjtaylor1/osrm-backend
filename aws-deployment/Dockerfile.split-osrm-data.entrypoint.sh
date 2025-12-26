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

source ./aws-deployment/split-osm.sh || handle_error "Could not source split-osm.sh"

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
mapfile -t files_to_process < <(split_osm "/data/${OSM_FILE}.osm.pbf")

# Process each split file
for split_file in "${files_to_process[@]}"; do
    remote_file="s3://my-osrm-data-715/output/$(basename "$split_file")"
    aws s3 cp --no-progress "$split_file" "$remote_file"
done
