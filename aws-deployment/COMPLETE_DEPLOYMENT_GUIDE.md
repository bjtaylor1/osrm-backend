# Complete OSRM Global Bicycle Routing Deployment Guide

This guide walks through deploying a production OSRM bicycle routing server that handles global queries using geographic slicing.

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                     Client Requests                          │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│               nginx (Port 80)                                │
│          Coordinates → Backend Mapping                       │
└───┬─────┬─────┬─────┬─────┬─────┬──────────────────────────┘
    │     │     │     │     │     │
    ▼     ▼     ▼     ▼     ▼     ▼
  :5000 :5001 :5002 :5003 :5004 :5005
    │     │     │     │     │     │
    ▼     ▼     ▼     ▼     ▼     ▼
┌────────────────────────────────────────────────────────────┐
│              OSRM Routed Instances                          │
│  North  │ South │ Europe│ Africa│  Asia │Oceania│          │
│ America│America│       │       │       │       │          │
└────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Local Machine
- AWS CLI configured with appropriate credentials
- Docker installed (for building images)
- Bash shell

### AWS Resources
- S3 bucket for storing OSM data and processed files
- EC2 key pair for SSH access
- VPC with at least one public subnet
- Security group allowing:
  - SSH (port 22) from your IP
  - HTTP (port 80) from anywhere (or restricted as needed)
- IAM role for EC2 with S3 read access

## Step-by-Step Deployment

### Step 1: Prepare Geographic Slice Definitions

The world is divided into 6 slices:

| Slice | Region | Bounding Box (W,S,E,N) | Approx Data Size |
|-------|--------|------------------------|------------------|
| A | North America | -170,15,-50,75 | 60 GB |
| B | South America | -85,-60,-30,15 | 25 GB |
| C | Europe + N. Africa | -25,30,60,75 | 50 GB |
| D | Sub-Saharan Africa | -20,-35,55,30 | 20 GB |
| E | Asia + Middle East | 60,-15,180,75 | 80 GB |
| F | Oceania | 110,-50,180,-10 | 15 GB |

### Step 2: Process OSM Data

**Option A: Using AWS Batch (Recommended - Parallel Processing)**

```bash
# 1. Create S3 bucket
aws s3 mb s3://my-osrm-bicycle-data --region us-east-1

# 2. Setup AWS Batch infrastructure
cd /Users/bentaylor/osrm-backend
./setup-aws-batch.sh setup-full \
    -r <your-account-id>.dkr.ecr.us-east-1.amazonaws.com \
    -j osrm-bicycle-job \
    -q osrm-bicycle-queue

# 3. Process world data (splits + extract + contract)
cd aws-deployment/scripts
chmod +x process-world-data.sh
./process-world-data.sh \
    --s3-bucket my-osrm-bicycle-data \
    --profile bicycle_paved \
    --use-batch true
```

This will:
- Download planet OSM file (~60 GB)
- Split into 6 geographic slices
- Process each slice in parallel using AWS Batch
- Upload processed files to S3

**Processing time:** 8-12 hours (parallel) vs 48+ hours (sequential)
**Cost:** ~$20-30 using spot instances

**Option B: Local Processing (Simpler but Slower)**

```bash
# Requires large instance (r5.2xlarge or similar) with 500+ GB disk
./process-world-data.sh \
    --s3-bucket my-osrm-bicycle-data \
    --profile bicycle_paved \
    --local
```

### Step 3: Deploy Production Server

```bash
# Make script executable
chmod +x deploy-server.sh

# Deploy EC2 instance
./deploy-server.sh \
    --s3-bucket my-osrm-bicycle-data \
    --instance-type i3.xlarge \
    --key-name my-ec2-keypair \
    --security-group sg-xxxxxxxxx \
    --region us-east-1

# This will output:
# - Instance ID
# - Public IP address
# - Commands to monitor progress
```

**What happens:**
1. Launches i3.xlarge EC2 instance
2. Downloads and compiles OSRM
3. Downloads processed data from S3
4. Configures supervisor to run 6 OSRM instances
5. Configures nginx for coordinate-based routing
6. Starts all services

**Initialization time:** 20-30 minutes

### Step 4: Monitor Deployment

```bash
# SSH into instance
ssh -i ~/.ssh/my-ec2-keypair.pem ubuntu@<instance-ip>

# Watch cloud-init progress
tail -f /var/log/cloud-init-output.log

# Check OSRM processes
sudo supervisorctl status

# Should show:
# osrm_slice_a                     RUNNING   pid 1234, uptime 0:05:23
# osrm_slice_b                     RUNNING   pid 1235, uptime 0:05:23
# osrm_slice_c                     RUNNING   pid 1236, uptime 0:05:23
# osrm_slice_d                     RUNNING   pid 1237, uptime 0:05:23
# osrm_slice_e                     RUNNING   pid 1238, uptime 0:05:23
# osrm_slice_f                     RUNNING   pid 1239, uptime 0:05:23

# Check nginx
sudo systemctl status nginx

# Test individual slices
curl "http://localhost:5000/route/v1/bicycle/-73.989,40.733;-73.982,40.742"
curl "http://localhost:5001/route/v1/bicycle/-43.189,-22.903;-43.182,22.912"
# etc for ports 5002-5005
```

### Step 5: Test the API

```bash
# Health check
curl http://<instance-ip>/health

# Test North America route (New York)
curl "http://<instance-ip>/route/v1/bicycle/-73.989,40.733;-73.982,40.742?steps=true&overview=full"

# Test Europe route (London)
curl "http://<instance-ip>/route/v1/bicycle/-0.127,51.507;-0.142,51.501?steps=true"

# Test Asia route (Tokyo)
curl "http://<instance-ip>/route/v1/bicycle/139.691,35.689;139.702,35.698?steps=true"

# Direct slice access for debugging
curl "http://<instance-ip>/slice/north_america/route/v1/bicycle/-73.989,40.733;-73.982,40.742"
curl "http://<instance-ip>/slice/europe/route/v1/bicycle/-0.127,51.507;-0.142,51.501"
```

### Step 6: Production Hardening

**A. Setup CloudWatch Monitoring**
```bash
# Install CloudWatch agent on EC2
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i amazon-cloudwatch-agent.deb

# Configure monitoring for OSRM processes and nginx
```

**B. Setup Auto-Recovery**
```bash
# Enable EC2 auto-recovery
aws ec2 modify-instance-attribute \
    --instance-id <instance-id> \
    --disable-api-termination
```

**C. Create AMI for Backup**
```bash
# Create image of configured instance
aws ec2 create-image \
    --instance-id <instance-id> \
    --name "osrm-bicycle-server-$(date +%Y%m%d)" \
    --description "OSRM bicycle routing server with global data"
```

**D. Setup Automated Backups**
```bash
# Create snapshot schedule for instance volumes
aws dlm create-lifecycle-policy \
    --policy-details file://backup-policy.json
```

### Step 7: (Optional) Setup Load Balancing

For high availability, deploy multiple instances behind an ALB:

```bash
# Create target group
aws elbv2 create-target-group \
    --name osrm-bicycle-tg \
    --protocol HTTP \
    --port 80 \
    --vpc-id <vpc-id> \
    --health-check-path /health

# Create ALB
aws elbv2 create-load-balancer \
    --name osrm-bicycle-alb \
    --subnets <subnet-1> <subnet-2> \
    --security-groups <sg-id>

# Register instances
aws elbv2 register-targets \
    --target-group-arn <tg-arn> \
    --targets Id=<instance-id-1> Id=<instance-id-2>
```

## Maintenance

### Updating OSM Data (Monthly Recommended)

```bash
# 1. Process new data in parallel
./process-world-data.sh \
    --s3-bucket my-osrm-bicycle-data \
    --use-batch true

# 2. Deploy new instance with updated data
./deploy-server.sh \
    --s3-bucket my-osrm-bicycle-data \
    --instance-type i3.xlarge \
    --key-name my-ec2-keypair \
    --security-group sg-xxxxxxxxx

# 3. Update load balancer to point to new instance
# 4. Terminate old instance
```

**Or update in-place:**
```bash
# SSH to server
ssh -i ~/.ssh/my-keypair.pem ubuntu@<instance-ip>

# Stop OSRM processes
sudo supervisorctl stop osrm:*

# Download new data
aws s3 sync s3://my-osrm-bicycle-data/processed/ /opt/osrm/data/

# Restart services
sudo supervisorctl start osrm:*
```

### Monitoring Commands

```bash
# Check memory usage
free -h

# Check OSRM process memory
ps aux | grep osrm-routed

# Check nginx access logs
tail -f /var/log/nginx/osrm_access.log

# Check OSRM logs
tail -f /opt/osrm/logs/slice_*.log

# Supervisor control
sudo supervisorctl status
sudo supervisorctl restart osrm:osrm_slice_a
sudo supervisorctl tail osrm_slice_a
```

## Costs

### Monthly Operational Costs

| Component | Configuration | Cost |
|-----------|--------------|------|
| EC2 i3.xlarge | Reserved 1-year | ~$112/mo |
| S3 Storage | 500 GB | ~$11.50/mo |
| Data Transfer | 1 TB out | ~$90/mo |
| CloudWatch | Basic monitoring | ~$5/mo |
| **Total** | | **~$220/mo** |

### One-Time Processing Costs

| Task | Resources | Cost |
|------|-----------|------|
| Initial data processing | Batch + Spot | ~$25 |
| Monthly updates | Batch + Spot | ~$8/mo |

## Troubleshooting

### OSRM Process Won't Start
```bash
# Check logs
sudo supervisorctl tail osrm_slice_a stderr

# Common issues:
# - Missing data files: verify S3 sync completed
# - Corrupted data: re-download from S3
# - Out of memory: check available RAM

# Manual test
/usr/local/bin/osrm-routed /opt/osrm/data/slice_a_north_america.osrm -p 5000
```

### Nginx Routing Issues
```bash
# Test nginx config
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx

# Check which backend is being used
curl -I http://localhost/route/v1/bicycle/-73.989,40.733;-73.982,40.742
# Look for: X-OSRM-Slice header
```

### High Memory Usage
```bash
# Reduce OSRM threads
# Edit /etc/supervisor/conf.d/osrm.conf
# Change --threads 2 to --threads 1

# Restart processes
sudo supervisorctl restart osrm:*
```

## Alternative Architectures

### Multi-Instance (Better HA, Higher Cost)
- Deploy 6 separate c5.large instances (one per slice)
- Use Route53 geo-routing
- Cost: ~$370/month

### Single Large Instance (Simpler, May Not Fit)
- Use r5.4xlarge with full world data
- No slicing needed
- Cost: ~$700/month
- May still exceed memory limits

### Containerized (ECS/Fargate)
- Package as Docker containers
- Use ECS Service with ALB
- Auto-scaling capable
- Cost: Similar to EC2 but more flexible

## Next Steps

1. **Security**: Setup HTTPS with Let's Encrypt
2. **Caching**: Add Redis for frequent routes
3. **Metrics**: Detailed CloudWatch dashboards
4. **Alerts**: SNS notifications for failures
5. **Geographic DNS**: Route53 latency-based routing for multi-region

## Support

For issues or questions:
- OSRM Documentation: http://project-osrm.org/docs/
- This deployment: Check logs in `/opt/osrm/logs/`