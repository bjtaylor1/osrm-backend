#!/bin/bash
# Deploy OSRM production server to EC2 with processed data

set -euo pipefail

# Configuration
S3_BUCKET="${S3_BUCKET:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-i3.xlarge}"
AMI_ID="${AMI_ID:-}"  # Will auto-detect Ubuntu 22.04 if not specified
KEY_NAME="${KEY_NAME:-}"
SECURITY_GROUP="${SECURITY_GROUP:-}"
SUBNET_ID="${SUBNET_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_NAME="${INSTANCE_NAME:-osrm-bicycle-server}"
VOLUME_SIZE="${VOLUME_SIZE:-100}"  # GB for root volume
PROFILE="bicycle_paved"

show_help() {
    cat << 'EOF'
Deploy OSRM Production Server

This script launches an EC2 instance, downloads processed OSRM data from S3,
configures nginx routing, and starts 6 osrm-routed instances.

Usage: ./deploy-server.sh [OPTIONS]

OPTIONS:
    --s3-bucket BUCKET        S3 bucket with processed data (required)
    --instance-type TYPE      EC2 instance type (default: i3.xlarge)
    --ami-id ID              AMI ID (default: auto-detect Ubuntu 22.04)
    --key-name NAME          SSH key pair name (required)
    --security-group ID      Security group ID (required)
    --subnet-id ID           Subnet ID (optional)
    --region REGION          AWS region (default: us-east-1)
    --instance-name NAME     Instance name tag (default: osrm-bicycle-server)
    --volume-size SIZE       Root volume size in GB (default: 100)
    -h, --help              Show this help

EXAMPLES:
    # Deploy with required parameters
    ./deploy-server.sh \
        --s3-bucket my-osrm-data-715 \
        --key-name my-keypair \
        --security-group sg-12345678

    # Deploy with custom instance type
    ./deploy-server.sh \
        --s3-bucket my-osrm-data-715 \
        --key-name my-keypair \
        --security-group sg-12345678 \
        --instance-type i3en.xlarge

SECURITY GROUP REQUIREMENTS:
    - Inbound: TCP 22 (SSH) from your IP
    - Inbound: TCP 80 (HTTP) for routing API
    - Inbound: TCP 5000-5005 (optional, for direct OSRM access)
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --s3-bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --ami-id)
            AMI_ID="$2"
            shift 2
            ;;
        --key-name)
            KEY_NAME="$2"
            shift 2
            ;;
        --security-group)
            SECURITY_GROUP="$2"
            shift 2
            ;;
        --subnet-id)
            SUBNET_ID="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --instance-name)
            INSTANCE_NAME="$2"
            shift 2
            ;;
        --volume-size)
            VOLUME_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if [[ -z "$S3_BUCKET" ]] || [[ -z "$KEY_NAME" ]] || [[ -z "$SECURITY_GROUP" ]]; then
    echo "Error: --s3-bucket, --key-name, and --security-group are required"
    show_help
    exit 1
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# Auto-detect Ubuntu AMI if not specified
get_ami_id() {
    if [[ -n "$AMI_ID" ]]; then
        echo "$AMI_ID"
        return
    fi
    
    log "Auto-detecting Ubuntu 22.04 AMI..."
    local ami=$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region "${AWS_REGION}")
    
    echo "$ami"
}

# Generate user data script
generate_userdata() {
    cat << 'USERDATA_EOF'
#!/bin/bash
set -euxo pipefail

# Update system
apt-get update
apt-get upgrade -y

# Install dependencies
apt-get install -y \
    build-essential \
    git \
    cmake \
    pkg-config \
    libboost-all-dev \
    libbz2-dev \
    liblua5.4-dev \
    libtbb-dev \
    libxml2-dev \
    libzip-dev \
    lua5.4 \
    nginx \
    supervisor \
    awscli \
    htop \
    curl \
    jq \
    nvme-cli

# Detect and mount instance store (NVMe)
log "Detecting instance store..."
INSTANCE_STORE_DEV=$(lsblk -d -n -o NAME,TYPE | grep disk | grep nvme | head -1 | awk '{print $1}')

if [[ -n "$INSTANCE_STORE_DEV" ]]; then
    log "Found instance store: /dev/$INSTANCE_STORE_DEV"
    
    # Format the instance store with ext4
    log "Formatting instance store..."
    mkfs.ext4 -F /dev/$INSTANCE_STORE_DEV
    
    # Create mount point
    mkdir -p /mnt/instance-store
    
    # Mount instance store
    log "Mounting instance store at /mnt/instance-store..."
    mount /dev/$INSTANCE_STORE_DEV /mnt/instance-store
    
    # Set up OSRM directories on instance store
    mkdir -p /mnt/instance-store/osrm/{data,logs}
    
    # Create symlinks to instance store
    mkdir -p /opt/osrm/bin
    ln -s /mnt/instance-store/osrm/data /opt/osrm/data
    ln -s /mnt/instance-store/osrm/logs /opt/osrm/logs
    
    # Create 100GB swapfile on instance store
    log "Creating 100GB swapfile on instance store..."
    dd if=/dev/zero of=/mnt/instance-store/swapfile bs=1G count=100
    chmod 600 /mnt/instance-store/swapfile
    mkswap /mnt/instance-store/swapfile
    swapon /mnt/instance-store/swapfile
    
    # Verify swap is active
    swapon --show
    
    log "Instance store mounted and configured for OSRM with 100GB swap"
else
    log "WARNING: No instance store found, using EBS storage"
    mkdir -p /opt/osrm/{data,bin,logs}
fi

cd /opt/osrm

# Download and compile OSRM (or use pre-built binaries)
log "Installing OSRM..."
git clone https://github.com/bjtaylor1/osrm-backend.git /tmp/osrm
cd /tmp/osrm
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_LTO=On
make -j$(nproc)
make install
cd /
rm -rf /tmp/osrm

# Download processed data from S3
log "Downloading processed OSRM data from S3..."
aws s3 sync s3://S3_BUCKET_PLACEHOLDER/processed/ /opt/osrm/data/ --region AWS_REGION_PLACEHOLDER

# Verify files
log "Verifying downloaded files..."
ls -lh /opt/osrm/data/

# Create supervisor configuration for OSRM processes
cat > /etc/supervisor/conf.d/osrm.conf << 'SUPERVISOR_EOF'
[group:osrm]
programs=osrm_slice_a,osrm_slice_b,osrm_slice_c,osrm_slice_d,osrm_slice_e,osrm_slice_f

[program:osrm_slice_a]
command=/usr/local/bin/osrm-routed /opt/osrm/data/slice_a_north_america.osrm --ip 127.0.0.1 --port 5000 --threads 2
directory=/opt/osrm
autostart=true
autorestart=true
stderr_logfile=/opt/osrm/logs/slice_a.err.log
stdout_logfile=/opt/osrm/logs/slice_a.out.log
user=root

[program:osrm_slice_b]
command=/usr/local/bin/osrm-routed /opt/osrm/data/slice_b_south_america.osrm --ip 127.0.0.1 --port 5001 --threads 2
directory=/opt/osrm
autostart=true
autorestart=true
stderr_logfile=/opt/osrm/logs/slice_b.err.log
stdout_logfile=/opt/osrm/logs/slice_b.out.log
user=root

[program:osrm_slice_c]
command=/usr/local/bin/osrm-routed /opt/osrm/data/slice_c_europe_africa.osrm --ip 127.0.0.1 --port 5002 --threads 2
directory=/opt/osrm
autostart=true
autorestart=true
stderr_logfile=/opt/osrm/logs/slice_c.err.log
stdout_logfile=/opt/osrm/logs/slice_c.out.log
user=root

[program:osrm_slice_d]
command=/usr/local/bin/osrm-routed /opt/osrm/data/slice_d_africa.osrm --ip 127.0.0.1 --port 5003 --threads 2
directory=/opt/osrm
autostart=true
autorestart=true
stderr_logfile=/opt/osrm/logs/slice_d.err.log
stdout_logfile=/opt/osrm/logs/slice_d.out.log
user=root

[program:osrm_slice_e]
command=/usr/local/bin/osrm-routed /opt/osrm/data/slice_e_asia.osrm --ip 127.0.0.1 --port 5004 --threads 2
directory=/opt/osrm
autostart=true
autorestart=true
stderr_logfile=/opt/osrm/logs/slice_e.err.log
stdout_logfile=/opt/osrm/logs/slice_e.out.log
user=root

[program:osrm_slice_f]
command=/usr/local/bin/osrm-routed /opt/osrm/data/slice_f_oceania.osrm --ip 127.0.0.1 --port 5005 --threads 2
directory=/opt/osrm
autostart=true
autorestart=true
stderr_logfile=/opt/osrm/logs/slice_f.err.log
stdout_logfile=/opt/osrm/logs/slice_f.out.log
user=root
SUPERVISOR_EOF

# Create nginx configuration with geographic routing
cat > /etc/nginx/sites-available/osrm << 'NGINX_EOF'
# Upstream definitions for each OSRM slice
upstream osrm_north_america {
    server 127.0.0.1:5000;
}
upstream osrm_south_america {
    server 127.0.0.1:5001;
}
upstream osrm_europe {
    server 127.0.0.1:5002;
}
upstream osrm_africa {
    server 127.0.0.1:5003;
}
upstream osrm_asia {
    server 127.0.0.1:5004;
}
upstream osrm_oceania {
    server 127.0.0.1:5005;
}

# Map to determine backend based on coordinates
map $request_uri $osrm_backend {
    default osrm_europe;
    # This is a simplified version - you'll need proper coordinate parsing
    # For now, use a default backend
}

server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/osrm_access.log;
    error_log /var/log/nginx/osrm_error.log;

    # Health check endpoint
    location /health {
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Route all OSRM requests
    # TODO: Implement coordinate-based routing logic
    location / {
        # For now, route to appropriate backend based on path analysis
        # In production, you'd parse coordinates and route accordingly
        proxy_pass http://osrm_europe;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    
    # Direct access to specific slices (for debugging)
    location /north_america/ {
        rewrite ^/north_america/(.*)$ /$1 break;
        proxy_pass http://osrm_north_america;
    }
    location /south_america/ {
        rewrite ^/south_america/(.*)$ /$1 break;
        proxy_pass http://osrm_south_america;
    }
    location /europe/ {
        rewrite ^/europe/(.*)$ /$1 break;
        proxy_pass http://osrm_europe;
    }
    location /africa/ {
        rewrite ^/africa/(.*)$ /$1 break;
        proxy_pass http://osrm_africa;
    }
    location /asia/ {
        rewrite ^/asia/(.*)$ /$1 break;
        proxy_pass http://osrm_asia;
    }
    location /oceania/ {
        rewrite ^/oceania/(.*)$ /$1 break;
        proxy_pass http://osrm_oceania;
    }
}
NGINX_EOF

# Enable nginx site
ln -sf /etc/nginx/sites-available/osrm /etc/nginx/sites-enabled/osrm
rm -f /etc/nginx/sites-enabled/default

# Test nginx configuration
nginx -t

# Start services
systemctl restart supervisor
systemctl restart nginx
systemctl enable supervisor
systemctl enable nginx

# Wait for services to start
sleep 10

# Verify OSRM processes are running
supervisorctl status

# Test OSRM endpoints
log "Testing OSRM endpoints..."
for port in 5000 5001 5002 5003 5004 5005; do
    if curl -s "http://127.0.0.1:${port}/health" > /dev/null; then
        log "Port ${port}: OK"
    else
        log "Port ${port}: FAILED"
    fi
done

log "OSRM server setup complete!"
log "Access the routing API at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
USERDATA_EOF
}

main() {
    log "Deploying OSRM production server"
    log "Instance type: ${INSTANCE_TYPE}"
    log "S3 bucket: ${S3_BUCKET}"
    log "Region: ${AWS_REGION}"
    
    # Get AMI ID
    local ami_id=$(get_ami_id)
    log "Using AMI: ${ami_id}"
    
    # Generate user data
    local userdata=$(generate_userdata | sed "s|S3_BUCKET_PLACEHOLDER|${S3_BUCKET}|g" | sed "s|AWS_REGION_PLACEHOLDER|${AWS_REGION}|g")
    
    # Prepare launch parameters
    local launch_params=(
        --image-id "$ami_id"
        --instance-type "$INSTANCE_TYPE"
        --key-name "$KEY_NAME"
        --security-group-ids "$SECURITY_GROUP"
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]"
        --user-data "$userdata"
        --region "$AWS_REGION"
        --iam-instance-profile "Name=OSRM-EC2-Role"
    )
    
    if [[ -n "$SUBNET_ID" ]]; then
        launch_params+=(--subnet-id "$SUBNET_ID")
    fi
    
    # Launch instance
    log "Launching EC2 instance..."
    local instance_id=$(aws ec2 run-instances \
        "${launch_params[@]}" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    if [[ -z "$instance_id" ]]; then
        error "Failed to launch instance"
    fi
    
    log "Instance launched: ${instance_id}"
    log "Waiting for instance to be running..."
    
    aws ec2 wait instance-running --instance-ids "$instance_id" --region "$AWS_REGION"
    
    # Get instance details
    local public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    log "Instance is running!"
    log "Instance ID: ${instance_id}"
    log "Public IP: ${public_ip}"
    log ""
    log "The server is initializing. This will take 15-30 minutes to:"
    log "  1. Download and compile OSRM"
    log "  2. Download processed data from S3"
    log "  3. Start all 6 OSRM instances"
    log ""
    log "You can monitor progress with:"
    log "  ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${public_ip} 'tail -f /var/log/cloud-init-output.log'"
    log ""
    log "Once ready, test the API:"
    log "  curl 'http://${public_ip}/route/v1/bicycle/-0.127,51.507;-0.142,51.501?steps=true'"
    log ""
    log "Direct slice access (for debugging):"
    log "  curl 'http://${public_ip}/europe/route/v1/bicycle/-0.127,51.507;-0.142,51.501'"
    
    echo "$instance_id" > .osrm-instance-id
    echo "$public_ip" > .osrm-instance-ip
}

main