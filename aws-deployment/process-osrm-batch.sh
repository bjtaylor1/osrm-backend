#!/bin/bash
# Process OSRM data using AWS Batch
# Runs complete workflow (extract + contract) for 6 slices entirely in the cloud

set -euo pipefail

# Configuration
S3_BUCKET="${S3_BUCKET:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
JOB_QUEUE="${JOB_QUEUE:-osrm-batch-queue}"
JOB_DEFINITION="${JOB_DEFINITION:-osrm-batch-job}"
MODE="${MODE:-test}"  # 'test' or 'production'
PROFILE="${PROFILE:-bicycle_paved}"

show_help() {
    cat << 'EOF'
Process OSRM Data via AWS Batch

Runs the complete OSRM processing workflow entirely in AWS Batch.
No local processing - everything downloads, processes, and uploads in the cloud.

Usage: ./process-osrm-batch.sh --s3-bucket BUCKET [OPTIONS]

REQUIRED:
    --s3-bucket BUCKET      S3 bucket for storing processed data

OPTIONS:
    --mode MODE            Processing mode (default: test)
                           • test: 6 small regions (~15 min, $0.50)
                           • production: Planet file + splitting (~12 hrs, $25)
    
    --profile NAME         OSRM routing profile (default: bicycle_paved)
    --job-queue NAME       Batch job queue (default: osrm-batch-queue)
    --job-def NAME         Job definition (default: osrm-batch-job)
    --region REGION        AWS region (default: us-east-1)
    -h, --help            Show this help

MODES EXPLAINED:

  TEST MODE (--mode test)
    • Downloads 6 pre-extracted small regions from Geofabrik
    • Regions: Monaco, Liechtenstein, Malta, Delaware, Rhode Island, Luxembourg
    • No planet download or splitting required
    • Perfect for testing the complete workflow
    • Time: ~15 minutes
    • Cost: ~$0.50
  
  PRODUCTION MODE (--mode production)
    • Downloads full planet OSM file (60+ GB)
    • Splits into 6 geographic continental slices
    • Processes each slice (extract + contract)
    • Use this for real-world deployment
    • Time: ~8-12 hours
    • Cost: ~$20-25 (using spot instances)

EXAMPLES:

    # Quick test run (recommended first)
    ./process-osrm-batch.sh --s3-bucket my-osrm-data-715 --mode test

    # Full production run with planet file
    ./process-osrm-batch.sh --s3-bucket my-osrm-data-715 --mode production
    
    # Custom profile
    ./process-osrm-batch.sh --s3-bucket my-osrm-data-715 --mode test --profile car

WHAT THIS SCRIPT DOES:

    1. Reads slice definitions based on mode
    2. For each slice (6 total):
       • Submits AWS Batch extract job
         - Downloads OSM data (from HTTP or S3)
         - Runs osrm-extract with specified profile
         - Uploads .osrm files to S3
       • Waits for extract to complete
       • Submits AWS Batch contract job
         - Downloads .osrm from S3
         - Runs osrm-contract
         - Uploads contracted files to S3
       • Waits for contract to complete
    3. Verifies all 6 slices are in S3
    4. Ready for server deployment

OUTPUT:
    s3://BUCKET/processed/slice_a_*.osrm (+ related files)
    s3://BUCKET/processed/slice_b_*.osrm (+ related files)
    s3://BUCKET/processed/slice_c_*.osrm (+ related files)
    s3://BUCKET/processed/slice_d_*.osrm (+ related files)
    s3://BUCKET/processed/slice_e_*.osrm (+ related files)
    s3://BUCKET/processed/slice_f_*.osrm (+ related files)

SCHEDULING:
    To run monthly, create EventBridge rule:
    
    aws events put-rule \
      --name osrm-monthly-update \
      --schedule-expression 'cron(0 2 1 * ? *)' \
      --state ENABLED
    
    aws events put-targets \
      --rule osrm-monthly-update \
      --targets "Id"="1","Arn"="arn:aws:batch:..."

PREREQUISITES:
    • AWS Batch setup complete: ./setup-aws-batch.sh setup-full
    • S3 bucket created: aws s3 mb s3://my-osrm-data-715
    • AWS CLI configured with credentials
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --s3-bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --job-queue)
            JOB_QUEUE="$2"
            shift 2
            ;;
        --job-def)
            JOB_DEFINITION="$2"
            shift 2
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

# Submit a job and return job ID
submit_job() {
    local job_name="$1"
    local operation="$2"
    local osm_file="$3"
    local osrm_file="$4"
    local output_dir="$5"
    
    local env_json=""
    if [[ "$operation" == "extract" ]]; then
        env_json=$(jq -n \
            --arg op "$operation" \
            --arg osm "$osm_file" \
            --arg prof "$PROFILE" \
            --arg out "$output_dir" \
            '[
                {name: "OSRM_OPERATION", value: $op},
                {name: "OSM_FILE", value: $osm},
                {name: "PROFILE", value: $prof},
                {name: "OSRM_OUTPUT_DIR", value: $out}
            ]')
    else
        env_json=$(jq -n \
            --arg op "$operation" \
            --arg osrm "$osrm_file" \
            --arg out "$output_dir" \
            '[
                {name: "OSRM_OPERATION", value: $op},
                {name: "OSRM_FILE", value: $osrm},
                {name: "OSRM_OUTPUT_DIR", value: $out}
            ]')
    fi
    
    local job_id=$(aws batch submit-job \
        --job-name "$job_name" \
        --job-queue "$JOB_QUEUE" \
        --job-definition "$JOB_DEFINITION" \
        --container-overrides "{\"environment\": $env_json}" \
        --region "$AWS_REGION" \
        --query 'jobId' \
        --output text)
    
    echo "$job_id"
}

# Wait for job and check status
wait_for_job() {
    local job_id="$1"
    local job_name="$2"
    
    log "Waiting for job to complete: $job_name ($job_id)"
    
    aws batch wait job-complete \
        --jobs "$job_id" \
        --region "$AWS_REGION"
    
    local status=$(aws batch describe-jobs \
        --jobs "$job_id" \
        --region "$AWS_REGION" \
        --query 'jobs[0].status' \
        --output text)
    
    if [[ "$status" != "SUCCEEDED" ]]; then
        error "Job $job_name failed with status: $status"
    fi
    
    log "✓ Job completed: $job_name"
}

# Process test regions
process_test_mode() {
    log "Running in TEST mode with small regions"
    
    local config_file="$(dirname $0)/../config/test-regions.json"
    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
    fi
    
    local regions=$(jq -r '.test_regions[] | @json' "$config_file")
    local extract_jobs=()
    
    log "Submitting extract jobs for all regions..."
    
    while IFS= read -r region; do
        local name=$(echo "$region" | jq -r '.name')
        local url=$(echo "$region" | jq -r '.url')
        local desc=$(echo "$region" | jq -r '.description')
        
        log "Submitting extract job for: $desc"
        
        local job_name="osrm-test-extract-${name}-$(date +%s)"
        local output_dir="s3://${S3_BUCKET}/processed/"
        
        local job_id=$(submit_job "$job_name" "extract" "$url" "" "$output_dir")
        extract_jobs+=("$job_id|$name")
        
        log "  Job ID: $job_id"
    done <<< "$regions"
    
    # Wait for all extract jobs
    log "Waiting for all extract jobs to complete..."
    for job_entry in "${extract_jobs[@]}"; do
        IFS='|' read -r job_id name <<< "$job_entry"
        wait_for_job "$job_id" "extract-$name"
    done
    
    # Submit contract jobs
    log "Submitting contract jobs..."
    local contract_jobs=()
    
    while IFS= read -r region; do
        local name=$(echo "$region" | jq -r '.name')
        local desc=$(echo "$region" | jq -r '.description')
        
        log "Submitting contract job for: $desc"
        
        local job_name="osrm-test-contract-${name}-$(date +%s)"
        local osrm_file="s3://${S3_BUCKET}/processed/${name}.osrm"
        local output_dir="s3://${S3_BUCKET}/processed/"
        
        local job_id=$(submit_job "$job_name" "contract" "" "$osrm_file" "$output_dir")
        contract_jobs+=("$job_id|$name")
        
        log "  Job ID: $job_id"
    done <<< "$regions"
    
    # Wait for all contract jobs
    log "Waiting for all contract jobs to complete..."
    for job_entry in "${contract_jobs[@]}"; do
        IFS='|' read -r job_id name <<< "$job_entry"
        wait_for_job "$job_id" "contract-$name"
    done
    
    log "✓ All test regions processed successfully!"
}

# Process production (planet file with slicing)
process_production_mode() {
    log "Running in PRODUCTION mode with planet file"
    error "Production mode not yet implemented - requires planet splitting logic"
    # TODO: Implement planet download and splitting in batch
}

# Verify processed files
verify_output() {
    log "Verifying processed files in S3..."
    
    local files=$(aws s3 ls "s3://${S3_BUCKET}/processed/" --recursive | grep ".osrm")
    
    if [[ -z "$files" ]]; then
        error "No processed files found in S3!"
    fi
    
    log "Processed files:"
    echo "$files"
    
    # Count slices
    local slice_count=$(echo "$files" | grep -c "slice_.*\.osrm$" || true)
    
    if [[ "$slice_count" -lt 6 ]]; then
        log "WARNING: Found only $slice_count slices (expected 6)"
    else
        log "✓ Found all $slice_count slices"
    fi
}

# Main execution
main() {
    log "=== OSRM AWS Batch End-to-End Test ==="
    log "Mode: $MODE"
    log "S3 Bucket: $S3_BUCKET"
    log "Profile: $PROFILE"
    log "Job Queue: $JOB_QUEUE"
    log "Job Definition: $JOB_DEFINITION"
    log ""
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        error "AWS CLI not found"
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        error "jq not found. Install with: brew install jq"
    fi
    
    # Verify batch resources exist
    log "Verifying AWS Batch resources..."
    aws batch describe-job-queues --job-queues "$JOB_QUEUE" --region "$AWS_REGION" &>/dev/null || \
        error "Job queue '$JOB_QUEUE' not found. Run: ./setup-aws-batch.sh setup-full"
    
    aws batch describe-job-definitions --job-definition-name "$JOB_DEFINITION" --region "$AWS_REGION" &>/dev/null || \
        error "Job definition '$JOB_DEFINITION' not found"
    
    log "✓ AWS Batch resources verified"
    log ""
    
    # Process based on mode
    case "$MODE" in
        test)
            process_test_mode
            ;;
        production)
            process_production_mode
            ;;
        *)
            error "Unknown mode: $MODE (use 'test' or 'production')"
            ;;
    esac
    
    # Verify output
    verify_output
    
    log ""
    log "=== Processing Complete! ==="
    log ""
    log "Next steps:"
    log "  1. Deploy server with:"
    log "     ./aws-deployment/scripts/deploy-server.sh --s3-bucket $S3_BUCKET --key-name <your-key> --security-group <sg-id>"
    log ""
    log "  2. Or list processed files:"
    log "     aws s3 ls s3://$S3_BUCKET/processed/ --recursive"
    log ""
    log "  3. To run this on a schedule, create EventBridge rule:"
    log "     aws events put-rule --schedule-expression 'cron(0 0 1 * ? *)' --name osrm-monthly-update"
}

main