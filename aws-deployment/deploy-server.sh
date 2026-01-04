#!/bin/bash
ROUTER_AMI=ami-00932b450f2b640d8

aws ec2 run-instances \
    --image-id $ROUTER_AMI \
    --instance-type i3.large \
    --iam-instance-profile Name=OSRM-Instance-Profile \
    --key-name gpxeditor_useast1 \
    --region us-east-1 \
    --user-data '#!/bin/bash
(
handle_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2
    exit 1
}
log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_progress "Server initializing at $(date)"

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
    lsblk
    handle_error "Instance store not found - exiting. We need the instance store to process the large amount of data"
elif [[ ${#NVME_DEVS[@]} -eq 1 ]]; then
    # Single drive - format and mount directly
    log_progress "Found 1 NVMe drive: ${NVME_DEVS[0]}"
    mkfs.ext4 -F ${NVME_DEVS[0]}
    mount ${NVME_DEVS[0]} /data
else
    log_error "Multiple nvme drives - ensure mdadm is installed and copy RAID code"
fi

log_progress "Creating swap space"
dd if=/dev/zero of=/data/swapfile bs=1G count=100
ls -lh /data/swapfile
chmod 600 /data/swapfile
mkswap /data/swapfile
swapon /data/swapfile

df -h

log_progress "Installing osrm-routed dependencies"
apt-get update
apt-get install -y --no-install-recommends \
    libboost-date-time1.81.0 \
    libboost-iostreams1.81.0 \
    libboost-program-options1.81.0 \
    libboost-thread1.81.0 \
    liblua5.4-0 \
    libtbb12 \
    expat

log_progress "Downloading osrm-routed binary"
aws s3 cp s3://my-osrm-data-715/software/osrm-routed /usr/local/bin/osrm-routed
chmod +x /usr/local/bin/osrm-routed

cd data/

log_progress "Downloading processed data"
aws s3 cp --recursive "s3://my-osrm-data-715/output/" ./ --exclude "*" --include "planet-latest.*" --exclude "*.osm.pbf"

) > /tmp/startup.log 2>&1
'