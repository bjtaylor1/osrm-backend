#!/bin/bash
# Script to process world OSM data into 6 geographic slices for OSRM

set -euo pipefail

# Configuration
S3_BUCKET="${S3_BUCKET:-}"
PLANET_URL="${PLANET_URL:-https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf}"
WORK_DIR="${WORK_DIR:-/mnt/data/osrm-processing}"
PROFILE="bicycle_paved"
AWS_REGION="${AWS_REGION:-us-east-1}"
USE_BATCH="${USE_BATCH:-true}"
PARALLEL_PROCESSING="${PARALLEL_PROCESSING:-true}"

# Geographic boundaries for slices (min_lon,min_lat,max_lon,max_lat)
declare -A SLICES=(
    ["slice_a_north_america"]="-170,15,-50,75"
    ["slice_b_south_america"]="-85,-60,-30,15"
    ["slice_c_europe_africa"]="-25,30,60,75"
    ["slice_d_africa"]="-20,-35,55,30"
    ["slice_e_asia"]="-60,-15,180,75"
    ["slice_f_oceania"]="110,-50,180,-10"
)

show_help() {
    cat << 'EOF'
Process World OSM Data for OSRM

This script downloads the planet OSM file, splits it into geographic slices,
and processes each slice using OSRM extract and contract operations.

Usage: ./process-world-data.sh [OPTIONS]

OPTIONS:
    --s3-bucket BUCKET      S3 bucket for storing processed data (required)
    --planet-url URL        URL to download planet file (default: OSM planet)
    --work-dir DIR          Working directory for processing (default: /mnt/data/osrm-processing)
    --profile NAME          OSRM profile to use (default: bicycle_paved)
    --use-batch true|false  Use AWS Batch for processing (default: true)
    --local                 Process locally instead of AWS Batch
    --region REGION         AWS region (default: us-east-1)
    -h, --help             Show this help

EXAMPLES:
    # Process using AWS Batch (recommended)
    ./process-world-data.sh --s3-bucket my-osrm-data-715

    # Process locally (requires large instance)
    ./process-world-data.sh --s3-bucket my-osrm-data-715 --local

REQUIREMENTS:
    - AWS CLI configured
    - osmium-tool installed (for splitting)
    - Sufficient disk space (500+ GB for planet file + processed data)
    - AWS Batch job definition and queue setup (if using batch)
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --s3-bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        --planet-url)
            PLANET_URL="$2"
            shift 2
            ;;
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --use-batch)
            USE_BATCH="$2"
            shift 2
            ;;
        --local)
            USE_BATCH="false"
            shift
            ;;
        --region)
            AWS_REGION="$2"
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

if [[ -z "$S3_BUCKET" ]]; then
    echo "Error: --s3-bucket required"
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

check_dependencies() {
    if ! command -v aws &> /dev/null; then
        error "AWS CLI not found"
    fi
    
    if [[ "$USE_BATCH" == "false" ]]; then
        if ! command -v osmium &> /dev/null; then
            error "osmium-tool not found. Install with: apt-get install osmium-tool"
        fi
        
        if ! command -v osrm-extract &> /dev/null; then
            error "osrm-extract not found. OSRM must be installed for local processing"
        fi
    fi
}

download_planet() {
    local planet_file="${WORK_DIR}/planet-latest.osm.pbf"
    
    log "Downloading planet file from ${PLANET_URL}"
    log "This may take several hours..."
    
    mkdir -p "${WORK_DIR}"
    
    if [[ -f "$planet_file" ]]; then
        log "Planet file already exists, skipping download"
        return
    fi
    
    wget -O "${planet_file}.tmp" "${PLANET_URL}" || error "Failed to download planet file"
    mv "${planet_file}.tmp" "${planet_file}"
    
    log "Planet file downloaded: ${planet_file}"
    log "File size: $(du -h ${planet_file} | cut -f1)"
    
    # Upload to S3 for backup
    log "Uploading planet file to S3..."
    aws s3 cp "${planet_file}" "s3://${S3_BUCKET}/source/planet-latest.osm.pbf" || log "S3 upload failed (continuing)"
}

split_planet() {
    local planet_file="${WORK_DIR}/planet-latest.osm.pbf"
    local slices_dir="${WORK_DIR}/slices"
    
    mkdir -p "${slices_dir}"
    
    log "Splitting planet file into ${#SLICES[@]} geographic slices..."
    
    for slice_name in "${!SLICES[@]}"; do
        local bbox="${SLICES[$slice_name]}"
        local output_file="${slices_dir}/${slice_name}.osm.pbf"
        
        if [[ -f "$output_file" ]]; then
            log "Slice ${slice_name} already exists, skipping"
            continue
        fi
        
        log "Extracting ${slice_name} with bbox ${bbox}..."
        
        osmium extract \
            --bbox "${bbox}" \
            --strategy complete_ways \
            -o "${output_file}" \
            "${planet_file}" || error "Failed to extract ${slice_name}"
        
        log "Created ${slice_name}: $(du -h ${output_file} | cut -f1)"
        
        # Upload slice to S3
        aws s3 cp "${output_file}" "s3://${S3_BUCKET}/slices/${slice_name}.osm.pbf"
    done
    
    log "All slices created successfully"
}

process_slice_local() {
    local slice_file="$1"
    local slice_name=$(basename "${slice_file%.osm.pbf}")
    local profile_path="$(dirname $0)/../profiles/${PROFILE}.lua"
    
    if [[ ! -f "$profile_path" ]]; then
        error "Profile not found: ${profile_path}"
    fi
    
    log "Processing ${slice_name} with profile ${PROFILE}..."
    
    # Extract
    log "Running osrm-extract on ${slice_name}..."
    osrm-extract "${slice_file}" \
        -p "${profile_path}" \
        --threads "$(nproc)" || error "Extract failed for ${slice_name}"
    
    # Contract
    local osrm_file="${slice_file%.osm.pbf}.osrm"
    log "Running osrm-contract on ${slice_name}..."
    osrm-contract "${osrm_file}" \
        --threads "$(nproc)" || error "Contract failed for ${slice_name}"
    
    # Upload all OSRM files to S3
    log "Uploading processed files for ${slice_name}..."
    local base_name="${slice_file%.osm.pbf}"
    for file in "${base_name}".osrm*; do
        if [[ -f "$file" ]]; then
            aws s3 cp "$file" "s3://${S3_BUCKET}/processed/$(basename $file)"
        fi
    done
    
    log "Completed processing ${slice_name}"
}

process_all_slices_local() {
    local slices_dir="${WORK_DIR}/slices"
    
    log "Processing all slices locally..."
    
    if [[ "$PARALLEL_PROCESSING" == "true" ]]; then
        log "Processing slices in parallel..."
        for slice_file in "${slices_dir}"/*.osm.pbf; do
            process_slice_local "$slice_file" &
        done
        wait
    else
        for slice_file in "${slices_dir}"/*.osm.pbf; do
            process_slice_local "$slice_file"
        done
    fi
    
    log "All slices processed"
}

process_slice_batch() {
    local slice_name="$1"
    local job_queue="${JOB_QUEUE:-osrm-batch-queue}"
    local job_def="${JOB_DEFINITION:-osrm-batch-job}"
    
    log "Submitting batch job for ${slice_name}..."
    
    local job_id=$(aws batch submit-job \
        --job-name "osrm-process-${slice_name}-$(date +%Y%m%d-%H%M%S)" \
        --job-queue "${job_queue}" \
        --job-definition "${job_def}" \
        --container-overrides "{
            \"environment\": [
                {\"name\": \"OSRM_OPERATION\", \"value\": \"extract\"},
                {\"name\": \"OSM_FILE\", \"value\": \"s3://${S3_BUCKET}/slices/${slice_name}.osm.pbf\"},
                {\"name\": \"PROFILE\", \"value\": \"${PROFILE}\"},
                {\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"s3://${S3_BUCKET}/processed/\"}
            ]
        }" \
        --region "${AWS_REGION}" \
        --query 'jobId' \
        --output text)
    
    echo "$job_id"
}

process_all_slices_batch() {
    log "Submitting AWS Batch jobs for all slices..."
    
    local job_ids=()
    
    # Submit extract jobs
    for slice_name in "${!SLICES[@]}"; do
        local extract_job_id=$(process_slice_batch "$slice_name")
        log "Submitted extract job for ${slice_name}: ${extract_job_id}"
        job_ids+=("$extract_job_id")
    done
    
    # Wait for all extract jobs to complete
    log "Waiting for extract jobs to complete..."
    for job_id in "${job_ids[@]}"; do
        aws batch wait job-complete --jobs "$job_id" --region "${AWS_REGION}"
    done
    
    # Submit contract jobs
    local contract_job_ids=()
    for slice_name in "${!SLICES[@]}"; do
        log "Submitting contract job for ${slice_name}..."
        
        local job_id=$(aws batch submit-job \
            --job-name "osrm-contract-${slice_name}-$(date +%Y%m%d-%H%M%S)" \
            --job-queue "${JOB_QUEUE:-osrm-batch-queue}" \
            --job-definition "${JOB_DEFINITION:-osrm-batch-job}" \
            --container-overrides "{
                \"environment\": [
                    {\"name\": \"OSRM_OPERATION\", \"value\": \"contract\"},
                    {\"name\": \"OSRM_FILE\", \"value\": \"s3://${S3_BUCKET}/processed/${slice_name}.osrm\"},
                    {\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"s3://${S3_BUCKET}/processed/\"}
                ]
            }" \
            --region "${AWS_REGION}" \
            --query 'jobId' \
            --output text)
        
        log "Submitted contract job for ${slice_name}: ${job_id}"
        contract_job_ids+=("$job_id")
    done
    
    # Wait for contract jobs
    log "Waiting for contract jobs to complete..."
    for job_id in "${contract_job_ids[@]}"; do
        aws batch wait job-complete --jobs "$job_id" --region "${AWS_REGION}"
    done
    
    log "All batch jobs completed"
}

main() {
    log "Starting OSRM world data processing"
    log "S3 Bucket: ${S3_BUCKET}"
    log "Profile: ${PROFILE}"
    log "Processing mode: $([ "$USE_BATCH" == "true" ] && echo "AWS Batch" || echo "Local")"
    
    check_dependencies
    
    # Step 1: Download planet file
    download_planet
    
    # Step 2: Split into slices
    split_planet
    
    # Step 3: Process slices
    if [[ "$USE_BATCH" == "true" ]]; then
        process_all_slices_batch
    else
        process_all_slices_local
    fi
    
    log "Processing complete!"
    log "Processed files available at: s3://${S3_BUCKET}/processed/"
    log ""
    log "Next steps:"
    log "  1. Deploy production server: ./deploy-server.sh --s3-bucket ${S3_BUCKET}"
    log "  2. Or manually download files: aws s3 sync s3://${S3_BUCKET}/processed/ /opt/osrm/data/"
}

main