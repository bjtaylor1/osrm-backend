#!/bin/bash
set -euo pipefail

echo 'in entrypoint script'
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

# setup big disk and swap space:
INSTANCE_STORE_DEV=$(lsblk -d -n -o NAME,TYPE | grep disk | grep nvme | head -1 | awk '{print $1}')
if [[ -n "$INSTANCE_STORE_DEV" ]]; then
    echo "Formatting instance store..."
    mkfs.ext4 -F /dev/$INSTANCE_STORE_DEV
    mount /dev/$INSTANCE_STORE_DEV /data

    echo "Creating swap space"
    dd if=/dev/zero of=/data/swapfile bs=1G count=50
    chmod 600 /data/swapfile
    mkswap /data/swapfile
    swapon /data/swapfile

    du -h /data

else
    lsblk
    handle_error "Instance store not found - exiting. We need the instance store to process the large amount of data"
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
for osm_file in "${files_to_process[@]}"; do
    base_name="${osm_file%.osm.pbf}"
    file_name=$(basename "$base_name")
    
    log_progress "Extracting ${file_name}"
    osrm-extract \
        "${osm_file}" \
        --profile "/src/profiles/${PROFILE?}.lua" \
        --threads "$(nproc)" \
        ${EXTRACT_EXTRA_ARGS:-}
    
    log_progress "Contracting ${file_name}"
    osrm-contract \
        "${base_name}" \
        --threads "$(nproc)" \
        ${CONTRACT_EXTRA_ARGS:-}
    
    log_progress "Uploading ${file_name}"
    for file in "${base_name}".osrm*; do
        aws s3 cp --no-progress "$file" "s3://my-osrm-data-715/output/$(basename "$file")"
    done
done
