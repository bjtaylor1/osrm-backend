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
    
    # Find all unmounted NVMe instance store devices (excluding root)
    mapfile -t NVME_DEVS < <(lsblk -d -n -o NAME,MOUNTPOINT | grep nvme | grep -v '/$' | awk '{print "/dev/" $1}')
    
    if [[ ${#NVME_DEVS[@]} -eq 0 ]]; then
        lsblk
        handle_error "Instance store not found - exiting. We need the instance store to process the large amount of data"
    elif [[ ${#NVME_DEVS[@]} -eq 1 ]]; then
        # Single drive - format and mount directly
        log_progress "Found 1 NVMe drive: ${NVME_DEVS[0]}"
        mkfs.ext4 -F ${NVME_DEVS[0]}
        mount ${NVME_DEVS[0]} /data
    else
        # Multiple drives - create RAID 0 for maximum performance
        log_progress "Found ${#NVME_DEVS[@]} NVMe drives: ${NVME_DEVS[*]}"
        log_progress "Creating RAID 0 array for maximum performance"
        
        mdadm --create /dev/md0 \
            --level=0 \
            --raid-devices=${#NVME_DEVS[@]} \
            ${NVME_DEVS[@]}
        
        log_progress "Formatting RAID array"
        mkfs.ext4 -F /dev/md0
        mount /dev/md0 /data
    fi
    
    log_progress "Creating swap space"
    dd if=/dev/zero of=/data/swapfile bs=1G count=100
    ls -lh /data/swapfile
    chmod 600 /data/swapfile
    mkswap /data/swapfile
    swapon /data/swapfile

    df -h
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