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
    INSTANCE_STORE_DEV=$(lsblk -d -n -o NAME,MOUNTPOINT | grep nvme | grep -v '/$' | head -1 | awk '{print $1}')
    if [[ -n "$INSTANCE_STORE_DEV" ]]; then
        mkfs /dev/$INSTANCE_STORE_DEV
        mount /dev/$INSTANCE_STORE_DEV /data
        dd if=/dev/zero of=/data/swapfile bs=1G count=50
        chmod 600 /data/swapfile
        mkswap /data/swapfile
        swapon /data/swapfile
    fi
fi

cd /data

log_progress "Not downloading - using already existing file"
mv /${OSM_FILE?}.osm.pbf /data/
#wget --no-verbose "${OSM_SOURCE?}"
#wget --no-verbose "${OSM_SOURCE?}.md5"
#md5sum -c "${OSM_FILE?}.osm.pbf.md5"

osrm-extract \
    "${OSM_FILE}.osm.pbf" \
    --profile "/src/profiles/${PROFILE}.lua" \
    --threads "$(nproc)"

osrm-contract \
    "${OSM_FILE}.osrm" \
    --threads "$(nproc)"

for file in "${OSM_FILE}".osrm*; do
    aws s3 cp --no-progress "$file" "s3://my-osrm-data-715/output/$(basename "$file")"
done
