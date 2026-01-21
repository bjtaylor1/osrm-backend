#!/bin/bash
(
set -euo pipefail

handle_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2
    exit 1
}
log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_progress "Server initializing at $(date)"

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

log_progress "Retrieving router region from instance tags"
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)
ROUTER_REGION=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=router-region" --query 'Tags[0].Value' --output text --region us-east-1)
if [[ -z "$ROUTER_REGION" || "$ROUTER_REGION" == "None" ]]; then
    handle_error "router-region tag not found on instance. Please tag the instance with router-region."
fi

log_progress "Retrieving swap space from instance tags"
SWAP_SPACE=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=swap-space" --query 'Tags[0].Value' --output text --region us-east-1)
if [[ -z "$SWAP_SPACE" || "$SWAP_SPACE" == "None" ]]; then
    handle_error "swap-space tag not found on instance. Please tag the instance with swap-space."
fi

if [[ ${#NVME_DEVS[@]} -eq 0 ]]; then
    #no instance stores
    if [[ "$ROUTER_REGION" == "planet-latest" ]]; then
        lsblk
        handle_error "Instance store not found - exiting. We need the instance store to process the large amount of data"
    else
        log_progress "No instance store found, but not required for region: $ROUTER_REGION"
    fi
elif [[ ${#NVME_DEVS[@]} -eq 1 ]]; then
    # Single drive - format and mount directly
    log_progress "Found 1 NVMe drive: ${NVME_DEVS[0]}"
    mkfs.ext4 -F ${NVME_DEVS[0]}
    mount ${NVME_DEVS[0]} /data
else
    handle_error "Multiple nvme drives - ensure mdadm is installed and run RAID code"
fi

log_progress "Creating swap space (${SWAP_SPACE}MB)"
dd if=/dev/zero of=/data/swapfile bs=1M count=$SWAP_SPACE #(small instance can't do bs=1G)
ls -lh /data/swapfile
chmod 600 /data/swapfile
mkswap /data/swapfile
swapon /data/swapfile

cd /data

log_progress "Downloading processed data for region: $ROUTER_REGION"
aws s3 cp --recursive "s3://my-osrm-data-715/output/" ./ --exclude "*" --include "${ROUTER_REGION}.*" --exclude "*.osm.pbf"

log_progress "Downloading nginx configuration"
aws s3 cp "s3://my-osrm-data-715/config/nginxconfig.txt" /etc/nginx/sites-available/default

log_progress "Testing nginx configuration"
nginx -t || handle_error "Invalid nginx configuration"

log_progress "Reloading nginx"
systemctl reload nginx

systemctl start router-${ROUTER_REGION}

) > /tmp/startup.log 2>&1
