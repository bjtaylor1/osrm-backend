# OSRM Global Bicycle Routing - AWS Deployment

## Architecture Overview

This deployment creates a production-ready OSRM routing server on AWS that handles global bicycle routing queries using geographic slicing.

### Components

1. **Data Processing** (AWS Batch + Spot Instances)
   - Downloads planet OSM file
   - Splits into 6 geographic slices
   - Processes each slice (extract + contract) in parallel
   - Uploads to S3

2. **Production Server** (EC2 i3.xlarge)
   - Downloads processed slices from S3
   - Runs 6 osrm-routed instances (one per slice)
   - nginx routes requests by coordinates
   - Auto-starts on boot

3. **Supporting Infrastructure**
   - S3 bucket for OSM data and processed files
   - CloudWatch for monitoring
   - Security groups for access control
   - (Optional) ELB for high availability

## Quick Start

```bash
# 1. Build and push Docker image
./setup-aws-batch.sh build-and-push -r <your-ecr-registry>

# 2. Process world data (creates 6 slices)
./process-world-data.sh --s3-bucket <your-bucket>

# 3. Deploy production server
./deploy-server.sh --s3-bucket <your-bucket> --instance-type i3.xlarge

# 4. Access routing API
curl "http://<server-ip>:5000/route/v1/bicycle/-73.989,40.733;-73.982,40.742?steps=true"
```

## Geographic Slices

| Slice | Region | Port | Approx Size |
|-------|--------|------|-------------|
| A | North America | 5000 | ~60 GB OSM |
| B | South America | 5001 | ~25 GB OSM |
| C | Europe + North Africa | 5002 | ~50 GB OSM |
| D | Sub-Saharan Africa | 5003 | ~20 GB OSM |
| E | Asia + Middle East | 5004 | ~80 GB OSM |
| F | Oceania | 5005 | ~15 GB OSM |

## File Structure

```
aws-deployment/
├── README.md (this file)
├── docker/
│   └── Dockerfile.production      # Production server image
├── scripts/
│   ├── setup-aws-batch.sh         # Setup AWS Batch for processing
│   ├── process-world-data.sh      # Download + split + process world data
│   ├── deploy-server.sh           # Deploy production EC2 server
│   ├── split-osm-data.sh          # Split planet file into slices
│   └── update-data.sh             # Update data on running server
├── config/
│   ├── nginx.conf                 # nginx routing configuration
│   ├── osrm-supervisor.conf       # Supervisor config for OSRM processes
│   └── slice-definitions.json     # Geographic boundaries for slices
├── terraform/                     # Infrastructure as Code
│   ├── main.tf
│   ├── batch.tf
│   └── ec2.tf
└── userdata/
    └── server-init.sh             # EC2 user data script
```

## Cost Estimate (Monthly)

- **i3.xlarge Reserved Instance**: ~$112/month
- **S3 Storage** (500 GB processed data): ~$11.50/month
- **Data Processing** (monthly updates via Spot): ~$5-10/month
- **Data Transfer**: Variable based on usage
- **Total**: ~$130-140/month

## Next Steps

Choose your deployment method:
1. **Manual**: Follow step-by-step in `docs/manual-deployment.md`
2. **Automated (Terraform)**: Use `terraform/` directory
3. **Batch Processing Only**: Use existing AWS Batch setup
