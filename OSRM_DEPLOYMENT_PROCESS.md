# OSRM Global Bicycle Routing Server Deployment Process

## Overview
This document describes the process for deploying a global OSRM bicycle routing server using geographic slices to handle the worldwide dataset.

## Current Architecture (6-Slice Setup)

### Server Configuration
- **Instance Type**: i3.xlarge (or similar)
- **OSRM Instances**: 6 parallel osrm-routed processes
- **Load Balancer**: nginx routing traffic to appropriate slice
- **Profile**: `profiles/bicycle_paved.lua`
- **Algorithm**: Contraction Hierarchies (CH) - using osrm-extract + osrm-contract

### Data Processing Pipeline

1. **Download Global OSM Data**
   ```bash
   wget https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf
   ```

2. **Split into Geographic Slices** (A, B, C, D, E, F)
   - Slice A: Geographic region 1
   - Slice B: Geographic region 2
   - Slice C: Geographic region 3
   - Slice D: Geographic region 4
   - Slice E: Geographic region 5
   - Slice F: Geographic region 6
   
   Tools for splitting:
   - osmium-tool: `osmium extract`
   - osmosis
   - Custom bounding boxes

3. **Process Each Slice**
   ```bash
   # For each slice (A-F):
   osrm-extract slice_A.osm.pbf -p profiles/bicycle_paved.lua
   osrm-contract slice_A.osrm
   
   osrm-extract slice_B.osm.pbf -p profiles/bicycle_paved.lua
   osrm-contract slice_B.osrm
   
   # ... repeat for C, D, E, F
   ```

4. **Deploy to Server**
   - Copy all processed .osrm files and associated data to EC2 instance
   - Start 6 osrm-routed processes, one per slice
   - Configure nginx to route requests based on coordinates

5. **Run Multiple OSRM Instances**
   ```bash
   osrm-routed slice_A.osrm -p 5000 &
   osrm-routed slice_B.osrm -p 5001 &
   osrm-routed slice_C.osrm -p 5002 &
   osrm-routed slice_D.osrm -p 5003 &
   osrm-routed slice_E.osrm -p 5004 &
   osrm-routed slice_F.osrm -p 5005 &
   ```

6. **Nginx Configuration**
   - Route incoming requests to correct slice based on lat/lon
   - Example: requests for coordinates in North America → slice_A (port 5000)

## Geographic Slice Recommendations

### Option 1: Six Continental Slices (Current)
- **Slice A**: North America
- **Slice B**: South America
- **Slice C**: Europe + North Africa
- **Slice D**: Sub-Saharan Africa
- **Slice E**: Asia + Middle East
- **Slice F**: Oceania

### Option 2: Population/Density-Based Slicing
More balanced by routing demand rather than geography:
- Slice 1: Western Europe (high density)
- Slice 2: Eastern Europe + Russia
- Slice 3: East Asia (China, Japan, Korea)
- Slice 4: Southeast Asia + India
- Slice 5: Americas (North + South)
- Slice 6: Rest of World (Africa, Oceania, Middle East)

### Option 3: Latitude Bands
Simpler routing logic:
- Slice A: 90°N to 60°N
- Slice B: 60°N to 30°N
- Slice C: 30°N to 0°
- Slice D: 0° to 30°S
- Slice E: 30°S to 60°S
- Slice F: 60°S to 90°S

## Alternative Architectures

### Multi-Instance Approach (More Expensive, Better Performance)
- Deploy 6 separate smaller EC2 instances (e.g., c5.large or m5.large)
- One slice per instance
- Use ALB (Application Load Balancer) with geographic routing
- **Pros**: Better isolation, independent scaling, redundancy
- **Cons**: Higher cost (~6x instance costs)

### Single Large Instance (Simpler, May Not Fit)
- Use very large instance (r5.4xlarge, r5.8xlarge)
- Run single OSRM process with full world data
- **Pros**: Simpler architecture, no routing complexity
- **Cons**: Very expensive, may still not fit full world with CH algorithm

### Hybrid: MLD Algorithm Instead of CH
- Use Multi-Level Dijkstra (MLD) instead of Contraction Hierarchies
- MLD has smaller memory footprint
- Process: osrm-extract → osrm-partition → osrm-customize
- **Pros**: Can potentially handle larger datasets
- **Cons**: Slightly slower query times than CH

## Cost-Effectiveness Analysis

### Current Setup (i3.xlarge)
- ~$312/month (on-demand)
- ~$112/month (1-year reserved)
- 4 vCPUs, 30.5 GB RAM, 950 GB NVMe SSD
- Can handle 6 slices

### Alternative: 6x c5.large
- ~$367/month (on-demand)
- Better CPU performance per slice
- No local NVMe storage (use EBS)
- Better fault isolation

### Alternative: 3x c5.xlarge
- Combine slices (2 per instance)
- ~$367/month (on-demand)
- Better redundancy with 3 instances
- Can take down one instance without full outage

### Recommendation
**Stick with single i3.xlarge for cost-effectiveness**, but consider:
- Using i3en.xlarge for more storage and better CPU
- Implementing automated failover with AMI snapshots
- Using spot instances for data processing, reserved for production

## Data Processing Options

### Option A: Process on Same Server
- Download OSM data directly to production instance
- Process in-place
- Requires downtime during data updates
- Simpler architecture

### Option B: Process on Separate Batch Instance
- Use AWS Batch (or separate EC2) for processing
- Transfer processed files to production instance
- Zero downtime updates (blue/green deployment)
- Can use cheaper spot instances for processing

### Option C: Hybrid
- Process small updates on production instance
- Use batch processing for full world rebuilds
- Best of both worlds

## Recommended Workflow

1. **Initial Setup**: Use AWS Batch to process all 6 slices in parallel
2. **Deploy**: Create AMI with OSRM + nginx configuration
3. **Launch**: Start i3.xlarge from AMI with processed data
4. **Updates**: Process new data via Batch, deploy new AMI or sync files
5. **Monitoring**: CloudWatch for instance health, nginx for request routing

## Tools Needed for Splitting

### Osmium Tool (Recommended)
```bash
# Install
apt-get install osmium-tool

# Extract by bounding box
osmium extract -b min_lon,min_lat,max_lon,max_lat planet.osm.pbf -o slice_A.osm.pbf

# Extract by polygon
osmium extract -p north_america.poly planet.osm.pbf -o slice_A.osm.pbf
```

### Osmosis (Alternative)
```bash
# Extract by bounding box
osmosis --read-pbf planet.osm.pbf \
  --bounding-box top=49.0 left=-125.0 bottom=25.0 right=-66.0 \
  --write-pbf slice_A.osm.pbf
```

## Memory Requirements Estimate

For bicycle routing with CH algorithm:
- **Small country (e.g., Netherlands)**: ~2-4 GB RAM
- **Large country (e.g., USA)**: ~16-32 GB RAM
- **Continent**: ~40-80 GB RAM
- **Full world**: 200+ GB RAM (too large for single instance)

Hence the 6-slice approach on i3.xlarge (30.5 GB) works well, giving ~5 GB per slice.

## nginx Routing Logic

```nginx
# Pseudo-configuration
map $arg_coordinates $backend {
    default slice_a;
    # Parse lat/lon from request
    # Route to appropriate backend
}

upstream slice_a { server 127.0.0.1:5000; }
upstream slice_b { server 127.0.0.1:5001; }
upstream slice_c { server 127.0.0.1:5002; }
upstream slice_d { server 127.0.0.1:5003; }
upstream slice_e { server 127.0.0.1:5004; }
upstream slice_f { server 127.0.0.1:5005; }

server {
    location / {
        proxy_pass http://$backend;
    }
}
```

## Future Improvements

1. **Auto-scaling**: Use ASG with multiple instances behind ALB
2. **Global Distribution**: CloudFront + regional servers
3. **Caching**: Redis/ElastiCache for frequent routes
4. **Monitoring**: Detailed metrics per slice
5. **Updates**: Automated weekly/monthly data refresh pipeline
