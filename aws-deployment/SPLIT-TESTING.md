# OSRM Split Testing Docker Image

This lightweight Docker image is designed specifically for testing the planet.osm.pbf splitting functionality without having to download the entire planet file each time or running the full OSRM processing pipeline.

## What It Does

The split testing image:
- Assumes `planet-latest.osm.pbf` is already present in the container (you mount it)
- Downloads the split configuration from S3 or local path
- Splits the planet file into geographical slices based on the configuration
- Optionally uploads the slices to S3 or keeps them locally
- Runs much faster than the full pipeline since it skips planet download and OSRM processing

## Prerequisites

1. **planet-latest.osm.pbf file**: Download it once and keep it locally
   ```bash
   cd aws-deployment
   wget https://planet.osm.org/pbf/planet-latest.osm.pbf
   ```

2. **Split configuration**: Either in S3 or locally in `config/planet-slices.json`

3. **Docker**: Installed and running

4. **AWS credentials** (if using S3): Set as environment variables

## Quick Start

### 1. Build the Image

```bash
cd aws-deployment
./build-split-image.sh
```

This creates the `osrm-split-test:latest` Docker image.

### 2. Run Split Test

#### Using S3 Configuration

```bash
SPLIT_CONFIG=s3://my-osrm-data-715/config/planet-slices.json ./run-split-test.sh
```

#### Using Local Configuration

```bash
SPLIT_CONFIG=config/planet-slices.json ./run-split-test.sh
```

#### With Custom Output Directory

```bash
SPLIT_CONFIG=s3://my-osrm-data-715/config/planet-slices.json \
OSRM_OUTPUT_DIR=s3://my-osrm-data-715/test-output \
./run-split-test.sh
```

## What Gets Created

After running the split test:

- **Slice files**: Created in `aws-deployment/output/` (if not uploading to S3)
- **Logs**: Written to `aws-deployment/logs/split-test.log`

## Comparison: Full Pipeline vs Split Testing

### Full Pipeline (Dockerfile.process-osrm-data)
- Downloads planet.osm.pbf (~70GB, takes hours)
- Splits into slices
- Runs osrm-extract on each slice
- Runs osrm-contract on each slice  
- Uploads OSRM files to S3
- **Time**: Hours per run

### Split Testing (Dockerfile.test-planet-split)
- Uses pre-downloaded planet.osm.pbf
- Splits into slices only
- Optionally uploads slices to S3
- **Time**: Minutes per run

## Environment Variables

- `SPLIT_CONFIG` (required): Path to split configuration JSON (S3 or local)
- `OSRM_OUTPUT_DIR` (optional): Where to save/upload slices (default: `/output`)
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`: AWS credentials
- `AWS_DEFAULT_REGION` (optional): AWS region (default: `us-east-1`)

## Example Split Configuration

```json
{
  "slices": [
    {
      "name": "slice_a",
      "minLongitude": 116.5,
      "maxLongitude": -98.5
    },
    {
      "name": "slice_b",
      "minLongitude": -98.5,
      "maxLongitude": 80.5
    },
    {
      "name": "slice_c",
      "minLongitude": 80.5,
      "maxLongitude": 116.5
    }
  ]
}
```

## Troubleshooting

### Planet file not found
Make sure `planet-latest.osm.pbf` exists in the `aws-deployment/` directory.

### AWS credentials error
Export your AWS credentials before running:
```bash
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
export AWS_DEFAULT_REGION=us-east-1
```

### bc: command not found
This has been fixed in both Dockerfiles by installing the `bc` package.

## Files

- `Dockerfile.test-planet-split`: The lightweight split testing image
- `build-split-image.sh`: Builds the Docker image
- `run-split-test.sh`: Runs the split test with proper volume mounts
- `SPLIT-TESTING.md`: This documentation file

## Benefits

1. **Faster iteration**: Test split configurations in minutes instead of hours
2. **No repeated downloads**: Use the same planet file for multiple tests
3. **Lower cost**: Less data transfer and compute time
4. **Easier debugging**: Focus on just the split logic without OSRM complexity
5. **Smaller image**: ~200MB vs ~2GB for the full image
