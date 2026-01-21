#!/bin/bash
set -euo pipefail

exec > >(tee -a /logs/process.log) 2>&1

handle_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2
    exit 1
}

log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

if [ ! -f "/data/nomount.flag" ]; then 
    echo "nomount.flag doesn't exist"
    lsblk
    # setup big disk and swap space (if not running locally):
    
    # Find all unmounted NVMe instance store devices (excluding boot device and any with mounted partitions)
    mapfile -t NVME_DEVS < <(
        for dev in /dev/nvme[0-9]*n[0-9]*; do
            # Skip if not a block device or if it's a partition (contains 'p')
            [ -b "$dev" ] || continue
            [[ "$dev" =~ p[0-9]+$ ]] && continue
            
            # Skip if device or any of its partitions are mounted
            if lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -q '^/.'; then
                continue
            fi
            
            # Only include disks larger than 100GB (instance stores are ~559GB)
            SIZE_GB=$(lsblk -b -d -n -o SIZE "$dev" 2>/dev/null | awk '{print int($1/1024/1024/1024)}')
            if [ "$SIZE_GB" -gt 10 ]; then
                echo "$dev"
            fi
        done
    )

    if [[ ${#NVME_DEVS[@]} -eq 0 ]]; then
        if [[ "$OSM_FILE" == "planet-latest" ]]; then
            handle_error "Instance store not found - exiting. We need the instance store to process the large amount of data"
        else
            log_progress "No instance store found, but not necessary for processing $OSM_FILE"
        fi
    elif [[ ${#NVME_DEVS[@]} -eq 1 ]]; then
        # Single drive - format and mount directly
        log_progress "Found 1 NVMe drive: ${NVME_DEVS[0]}"
        mkfs.ext4 -F ${NVME_DEVS[0]}
        mount ${NVME_DEVS[0]} /data
    else
        # Multiple drives - create RAID 0 for maximum performance
        log_progress "Found ${#NVME_DEVS[@]} NVMe drives: ${NVME_DEVS[*]}"
        log_progress "Creating RAID 0 array for maximum performance"
        
        # Wipe any existing filesystem signatures from the devices
        for dev in "${NVME_DEVS[@]}"; do
            log_progress "Wiping filesystem signatures from $dev"
            wipefs -a "$dev" || true
        done
        
        mdadm --create /dev/md0 \
            --level=0 \
            --raid-devices=${#NVME_DEVS[@]} \
            ${NVME_DEVS[@]}
        
        log_progress "Formatting RAID array"
        mkfs.ext4 -F /dev/md0
        mount /dev/md0 /data

        log_progress "Creating swap space"
        dd if=/dev/zero of=/data/swapfile bs=1G count=100
        ls -lh /data/swapfile
        chmod 600 /data/swapfile
        mkswap /data/swapfile
        swapon /data/swapfile

    fi
else
    log_progress "nomount.flag exists (must be running locally)"
fi

df -h
cd /data

if [[ -f ${OSM_FILE}.osm.pbf ]]; then
    log_progress "Not downloading - using already existing file"
else
    wget --no-verbose "${OSM_SOURCE?}"
    wget --no-verbose "${OSM_SOURCE?}.md5"
    md5sum -c "${OSM_FILE?}.osm.pbf.md5"
fi

osrm-extract \
    "${OSM_FILE}.osm.pbf" \
    --profile "/src/profiles/${PROFILE}.lua" \
    --threads "$(nproc)"

osrm-contract \
    "${OSM_FILE}.osrm" \
    --threads "$(nproc)"

for file in "${OSM_FILE}".osrm*; do
    aws s3 cp --no-progress "$file" "s3://my-osrm-data-715/output/${PROFILE}/$(basename "$file")"
done
