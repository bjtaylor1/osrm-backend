#!/bin/bash

# Example job submission scripts for OSRM AWS Batch

set -euo pipefail

# Configuration
JOB_QUEUE="osrm-batch-queue"
JOB_DEFINITION="osrm-batch-job"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

show_help() {
    cat << 'EOF'
OSRM AWS Batch Job Submission Examples

Usage: ./submit-jobs.sh [OPTIONS] COMMAND

COMMANDS:
    extract-job         Submit OSM extraction job
    contract-job        Submit contraction job
    partition-job       Submit partition job
    customize-job       Submit customization job
    pipeline-job        Submit complete pipeline job
    routed-job          Submit routing server job
    
OPTIONS:
    -q, --queue NAME       Job queue name
    -d, --job-def NAME     Job definition name
    -r, --region REGION    AWS region
    -h, --help            Show this help

ENVIRONMENT VARIABLES:
    S3_BUCKET             S3 bucket for input/output files
    OSM_FILE              OSM file path (local or S3)
    PROFILE               Routing profile (car, bicycle, foot)
    
EXAMPLES:
    # Extract Monaco OSM data
    S3_BUCKET=my-osrm-bucket OSM_FILE=monaco.osm.pbf PROFILE=car ./submit-jobs.sh extract-job
    
    # Run complete pipeline
    S3_BUCKET=my-osrm-bucket OSM_FILE=germany.osm.pbf PROFILE=car ./submit-jobs.sh pipeline-job
EOF
}

# Parse arguments
COMMAND=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -q|--queue)
            JOB_QUEUE="$2"
            shift 2
            ;;
        -d|--job-def)
            JOB_DEFINITION="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            COMMAND="$1"
            shift
            ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    echo "Error: Command required"
    show_help
    exit 1
fi

# Utility functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

submit_job() {
    local job_name="$1"
    local job_def="$2"
    local job_queue="$3"
    shift 3
    local env_vars=("$@")
    
    log "Submitting job: $job_name"
    
    local env_json=""
    if [[ ${#env_vars[@]} -gt 0 ]]; then
        env_json=$(printf '%s\n' "${env_vars[@]}" | jq -R . | jq -s .)
    else
        env_json="[]"
    fi
    
    local job_id=$(aws batch submit-job \
        --job-name "$job_name" \
        --job-queue "$job_queue" \
        --job-definition "$job_def" \
        --container-overrides "{\"environment\": $env_json}" \
        --region "$AWS_REGION" \
        --query 'jobId' \
        --output text)
    
    if [[ $? -eq 0 ]]; then
        log "Job submitted successfully: $job_id"
        echo "$job_id"
    else
        error "Failed to submit job"
    fi
}

wait_for_job() {
    local job_id="$1"
    log "Waiting for job to complete: $job_id"
    
    aws batch wait job-complete \
        --jobs "$job_id" \
        --region "$AWS_REGION"
    
    local status=$(aws batch describe-jobs \
        --jobs "$job_id" \
        --region "$AWS_REGION" \
        --query 'jobs[0].status' \
        --output text)
    
    log "Job $job_id completed with status: $status"
    
    if [[ "$status" != "SUCCEEDED" ]]; then
        error "Job failed with status: $status"
    fi
}

# Job submission functions
submit_extract_job() {
    local osm_file="${OSM_FILE:-}"
    local profile="${PROFILE:-car}"
    local s3_bucket="${S3_BUCKET:-}"
    
    [[ -n "$osm_file" ]] || error "OSM_FILE environment variable required"
    [[ -n "$s3_bucket" ]] || error "S3_BUCKET environment variable required"
    
    local job_name="osrm-extract-$(date +%Y%m%d-%H%M%S)"
    local s3_osm_path="s3://${s3_bucket}/input/${osm_file}"
    local s3_output_path="s3://${s3_bucket}/output/"
    
    local env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"extract\"}"
        "{\"name\": \"OSM_FILE\", \"value\": \"${s3_osm_path}\"}"
        "{\"name\": \"PROFILE\", \"value\": \"${profile}\"}"
        "{\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"${s3_output_path}\"}"
    )
    
    submit_job "$job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${env_vars[@]}"
}

submit_contract_job() {
    local osrm_file="${OSRM_FILE:-}"
    local s3_bucket="${S3_BUCKET:-}"
    
    [[ -n "$osrm_file" ]] || error "OSRM_FILE environment variable required"
    [[ -n "$s3_bucket" ]] || error "S3_BUCKET environment variable required"
    
    local job_name="osrm-contract-$(date +%Y%m%d-%H%M%S)"
    local s3_osrm_path="s3://${s3_bucket}/output/${osrm_file}"
    local s3_output_path="s3://${s3_bucket}/output/"
    
    local env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"contract\"}"
        "{\"name\": \"OSRM_FILE\", \"value\": \"${s3_osrm_path}\"}"
        "{\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"${s3_output_path}\"}"
    )
    
    submit_job "$job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${env_vars[@]}"
}

submit_partition_job() {
    local osrm_file="${OSRM_FILE:-}"
    local s3_bucket="${S3_BUCKET:-}"
    
    [[ -n "$osrm_file" ]] || error "OSRM_FILE environment variable required"
    [[ -n "$s3_bucket" ]] || error "S3_BUCKET environment variable required"
    
    local job_name="osrm-partition-$(date +%Y%m%d-%H%M%S)"
    local s3_osrm_path="s3://${s3_bucket}/output/${osrm_file}"
    local s3_output_path="s3://${s3_bucket}/output/"
    
    local env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"partition\"}"
        "{\"name\": \"OSRM_FILE\", \"value\": \"${s3_osrm_path}\"}"
        "{\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"${s3_output_path}\"}"
    )
    
    submit_job "$job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${env_vars[@]}"
}

submit_customize_job() {
    local osrm_file="${OSRM_FILE:-}"
    local s3_bucket="${S3_BUCKET:-}"
    
    [[ -n "$osrm_file" ]] || error "OSRM_FILE environment variable required"
    [[ -n "$s3_bucket" ]] || error "S3_BUCKET environment variable required"
    
    local job_name="osrm-customize-$(date +%Y%m%d-%H%M%S)"
    local s3_osrm_path="s3://${s3_bucket}/output/${osrm_file}"
    local s3_output_path="s3://${s3_bucket}/output/"
    local base_name=$(basename "${osrm_file%.*}")
    local s3_base_path="s3://${s3_bucket}/output/${base_name}"
    
    local env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"customize\"}"
        "{\"name\": \"OSRM_FILE\", \"value\": \"${s3_osrm_path}\"}"
        "{\"name\": \"OSRM_FILE_BASE\", \"value\": \"${s3_base_path}\"}"
        "{\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"${s3_output_path}\"}"
    )
    
    submit_job "$job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${env_vars[@]}"
}

submit_pipeline_job() {
    local osm_file="${OSM_FILE:-}"
    local profile="${PROFILE:-car}"
    local s3_bucket="${S3_BUCKET:-}"
    local algorithm="${ALGORITHM:-MLD}"
    
    [[ -n "$osm_file" ]] || error "OSM_FILE environment variable required"
    [[ -n "$s3_bucket" ]] || error "S3_BUCKET environment variable required"
    
    local job_name="osrm-pipeline-$(date +%Y%m%d-%H%M%S)"
    local s3_osm_path="s3://${s3_bucket}/input/${osm_file}"
    local s3_output_path="s3://${s3_bucket}/output/"
    
    local env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"extract\"}"
        "{\"name\": \"OSM_FILE\", \"value\": \"${s3_osm_path}\"}"
        "{\"name\": \"PROFILE\", \"value\": \"${profile}\"}"
        "{\"name\": \"ALGORITHM\", \"value\": \"${algorithm}\"}"
        "{\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"${s3_output_path}\"}"
    )
    
    # Submit extract job first
    log "Submitting pipeline job (extract -> partition -> customize)"
    local job_id=$(submit_job "$job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${env_vars[@]}")
    
    # Wait for extract to complete
    wait_for_job "$job_id"
    
    # Submit partition job
    local base_name=$(basename "${osm_file%.*}")
    local partition_job_name="osrm-partition-$(date +%Y%m%d-%H%M%S)"
    local partition_env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"partition\"}"
        "{\"name\": \"OSRM_FILE\", \"value\": \"s3://${s3_bucket}/output/${base_name}.osrm\"}"
        "{\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"${s3_output_path}\"}"
    )
    
    local partition_job_id=$(submit_job "$partition_job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${partition_env_vars[@]}")
    wait_for_job "$partition_job_id"
    
    # Submit customize job
    local customize_job_name="osrm-customize-$(date +%Y%m%d-%H%M%S)"
    local customize_env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"customize\"}"
        "{\"name\": \"OSRM_FILE\", \"value\": \"s3://${s3_bucket}/output/${base_name}.osrm\"}"
        "{\"name\": \"OSRM_FILE_BASE\", \"value\": \"s3://${s3_bucket}/output/${base_name}\"}"
        "{\"name\": \"OSRM_OUTPUT_DIR\", \"value\": \"${s3_output_path}\"}"
    )
    
    local customize_job_id=$(submit_job "$customize_job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${customize_env_vars[@]}")
    wait_for_job "$customize_job_id"
    
    log "Pipeline completed successfully!"
}

submit_routed_job() {
    local osrm_file="${OSRM_FILE:-}"
    local s3_bucket="${S3_BUCKET:-}"
    local port="${OSRM_PORT:-5000}"
    
    [[ -n "$osrm_file" ]] || error "OSRM_FILE environment variable required"
    [[ -n "$s3_bucket" ]] || error "S3_BUCKET environment variable required"
    
    local job_name="osrm-routed-$(date +%Y%m%d-%H%M%S)"
    local base_name=$(basename "${osrm_file%.*}")
    local s3_osrm_path="s3://${s3_bucket}/output/${osrm_file}"
    local s3_base_path="s3://${s3_bucket}/output/${base_name}"
    
    local env_vars=(
        "{\"name\": \"OSRM_OPERATION\", \"value\": \"routed\"}"
        "{\"name\": \"OSRM_FILE\", \"value\": \"${s3_osrm_path}\"}"
        "{\"name\": \"OSRM_FILE_BASE\", \"value\": \"${s3_base_path}\"}"
        "{\"name\": \"OSRM_PORT\", \"value\": \"${port}\"}"
    )
    
    submit_job "$job_name" "$JOB_DEFINITION" "$JOB_QUEUE" "${env_vars[@]}"
}

# Execute command
case "$COMMAND" in
    extract-job)
        submit_extract_job
        ;;
    contract-job)
        submit_contract_job
        ;;
    partition-job)
        submit_partition_job
        ;;
    customize-job)
        submit_customize_job
        ;;
    pipeline-job)
        submit_pipeline_job
        ;;
    routed-job)
        submit_routed_job
        ;;
    *)
        echo "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac