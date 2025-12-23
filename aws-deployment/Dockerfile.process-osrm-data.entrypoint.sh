#!/bin/bash
set -euo pipefail

trap 'echo "$(date "+%Y-%m-%d %H:%M:%S") - FATAL ERROR at line $LINENO: Command failed with exit code $?" >&2' ERR

exec > >(tee -a ${OSRM_LOG_DIR}/process-osrm-data.log) 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting OSRM AWS Batch processing"
echo "Container ID: ${HOSTNAME}"
echo "AWS Region: ${AWS_DEFAULT_REGION:-not set}"
echo "Data directory: ${OSRM_DATA_DIR}"
echo "Output directory: ${OSRM_OUTPUT_DIR}"
echo "OSRM Operation: ${OSRM_OPERATION:-NOT SET}"

handle_error() {
    local error_msg="$1"
    local line_no="${2:-unknown}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR at line ${line_no}: ${error_msg}" >&2
    exit 1
}

log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Source the split function
source /scripts/split-osm.sh

# Function to download from S3, HTTP, or local file
download_file() {
    local remote_path="$1"
    local local_path="$2"
    
    if [[ "$remote_path" == s3://* ]]; then
        log_progress "Downloading $remote_path to $local_path"
        aws s3 cp "$remote_path" "$local_path" || handle_error "Failed to download $remote_path"
    elif [[ "$remote_path" == http://* ]] || [[ "$remote_path" == https://* ]]; then
        log_progress "Downloading $remote_path to $local_path"
        wget -O --no-verbose "$local_path" "$remote_path" || handle_error "Failed to download $remote_path"
    else
        log_progress "Using local file: $remote_path"
        cp "$remote_path" "$local_path" || handle_error "Failed to copy $remote_path"
    fi
}

# Function to upload to S3 if needed
upload_s3_file() {
    local local_path="$1"
    local s3_path="$2"
    
    if [[ "$s3_path" == s3://* ]]; then
        log_progress "Uploading $local_path to $s3_path"
        aws s3 cp "$local_path" "$s3_path" || handle_error "Failed to upload to $s3_path"
    else
        log_progress "Copying to local destination: $s3_path"
        cp "$local_path" "$s3_path" || handle_error "Failed to copy to $s3_path"
    fi
}

# Validate required environment variables based on operation
validate_env_vars() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Validating environment variables for operation: ${OSRM_OPERATION:-NONE}"
    
    case "${OSRM_OPERATION:-}" in
        extract)
            [[ -n "${OSM_FILE:-}" ]] || handle_error "OSM_FILE is required for extract operation" $LINENO
            [[ -n "${PROFILE:-}" ]] || handle_error "PROFILE is required for extract operation" $LINENO
            echo "  ✓ OSM_FILE: ${OSM_FILE}"
            echo "  ✓ PROFILE: ${PROFILE}"
            ;;
        contract)
            [[ -n "${OSRM_FILE:-}" ]] || handle_error "OSRM_FILE is required for ${OSRM_OPERATION} operation" $LINENO
            echo "  ✓ OSRM_FILE: ${OSRM_FILE}"
            ;;
        routed)
            [[ -n "${OSRM_FILE:-}" ]] || handle_error "OSRM_FILE is required for routed operation" $LINENO
            echo "  ✓ OSRM_FILE: ${OSRM_FILE}"
            ;;
        pipeline)
            [[ -n "${OSM_FILE:-}" ]] || handle_error "OSM_FILE is required for pipeline operation" $LINENO
            [[ -n "${PROFILE:-}" ]] || handle_error "PROFILE is required for pipeline operation" $LINENO
            echo "  ✓ OSM_FILE: ${OSM_FILE}"
            echo "  ✓ PROFILE: ${PROFILE}"
            echo "  ✓ OSRM_OUTPUT_DIR: ${OSRM_OUTPUT_DIR:-not set}"
            ;;
        help)
            # No validation needed for help
            ;;
        *)
            handle_error "Unknown or missing OSRM_OPERATION: '${OSRM_OPERATION:-}'. Valid operations: extract, contract, pipeline, routed, help" $LINENO
            ;;
    esac
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Environment validation passed"
}

# Main processing function
main() {
    validate_env_vars
    
    log_progress "Starting ${OSRM_OPERATION} operation"
    
    case "${OSRM_OPERATION}" in
        extract)
            local osm_local_file="${OSRM_DATA_DIR}/input.osm.pbf"
            local profile_path="/opt/${PROFILE}.lua"
            local output_file="${OSRM_OUTPUT_DIR}/$(basename ${OSM_FILE%.*}).osrm"
            
            # Download OSM file
            download_file "${OSM_FILE}" "${osm_local_file}"
            
            # Validate profile exists
            [[ -f "${profile_path}" ]] || handle_error "Profile ${PROFILE}.lua not found"
            
            # Run extract
            log_progress "Running osrm-extract with profile ${PROFILE}"
            /usr/local/bin/osrm-extract \
                "${osm_local_file}" \
                --profile "${profile_path}" \
                --threads "$(nproc)" \
                ${EXTRACT_EXTRA_ARGS:-} || handle_error "osrm-extract failed"
            
            # Upload all generated OSRM files
            for file in "${OSRM_DATA_DIR}"/input.osrm*; do
                log_progress "Uploading $(basename "$file")"
                upload_s3_file "$file" "${OSRM_OUTPUT_DIR}/$(basename "$file")"
            done
            ;;
            
        contract)
            # Download OSRM file to /data/input.osrm
            download_file "${OSRM_FILE}" "${OSRM_DATA_DIR}/input.osrm"
            
            # Run contract - pass /data/input (without .osrm extension)
            log_progress "Running osrm-contract on ${OSRM_DATA_DIR}/input"
            /usr/local/bin/osrm-contract \
                "${OSRM_DATA_DIR}/input" \
                --threads "$(nproc)" \
                ${CONTRACT_EXTRA_ARGS:-} || handle_error "osrm-contract failed"
            
            # Upload all generated OSRM files
            for file in "${OSRM_DATA_DIR}"/input.osrm.*; do
                log_progress "Uploading $(basename "$file")"
                upload_s3_file "$file" "${OSRM_OUTPUT_DIR}/$(basename "$file")"
            done
            ;;

        routed)
            local osrm_local_file="${OSRM_DATA_DIR}/input.osrm"
            
            # Download OSRM file and all required files
            download_file "${OSRM_FILE}" "${osrm_local_file}"
            
            # Download all related files
            local base_name=$(basename ${osrm_local_file%.*})
            if [[ -n "${OSRM_FILE_BASE:-}" ]]; then
                for ext in names restrictions maneuver_overrides turn_weight_penalties turn_duration_penalties datasource_names hsgr level core partition cells cell_metrics mld; do
                    local s3_file="${OSRM_FILE_BASE}.osrm.${ext}"
                    local local_file="${OSRM_DATA_DIR}/${base_name}.osrm.${ext}"
                    if aws s3 ls "$s3_file" >/dev/null 2>&1; then
                        download_file "$s3_file" "$local_file"
                    fi
                done
            fi
            
            # Start OSRM routed
            log_progress "Starting osrm-routed server"
            /usr/local/bin/osrm-routed \
                "${osrm_local_file}" \
                --ip 0.0.0.0 \
                --port "${OSRM_PORT:-5000}" \
                --threads "$(nproc)" \
                ${ROUTED_EXTRA_ARGS:-} || handle_error "osrm-routed failed"
            ;;
            
        help)
            echo "=========================================="
            echo "OSRM AWS Batch Container"
            echo "=========================================="
            echo ""
            echo "OSRM Version Information:"
            /usr/local/bin/osrm-extract --version || true
            echo ""
            echo "Available Operations:"
            echo "  extract   - Extract routing data from OSM file"
            echo "  contract  - Contract the routing graph (CH)"
            echo "  pipeline  - Complete pipeline (download → split if needed → extract → contract → upload)"
            echo "  routed    - Start OSRM routing server"
            echo ""
            echo "Available OSRM Tools:"
            ls -1 /usr/local/bin/osrm-*
            echo ""
            echo "Available Profiles:"
            ls -1 /opt/*.lua
            echo ""
            echo "System Information:"
            echo "  CPUs: $(nproc)"
            echo "  Memory: $(free -h | grep Mem | awk '{print $2}')"
            echo "  AWS Region: ${AWS_DEFAULT_REGION:-not set}"
            echo "=========================================="
            ;;
            
        pipeline)
            local osm_local_file="${OSRM_DATA_DIR}/input.osm.pbf"
            local profile_path="/opt/${PROFILE}.lua"
            
            download_file "${OSM_FILE}" "${osm_local_file}"
            [[ -f "${profile_path}" ]] || handle_error "Profile ${PROFILE}.lua not found"
            
            # Split the OSM file (returns array of files to process)
            mapfile -t files_to_process < <(split_osm "$osm_local_file")
            
            log_progress "Processing ${#files_to_process[@]} file(s)"
            
            # Process each file (extract + contract)
            for osm_file in "${files_to_process[@]}"; do
                local base_name="${osm_file%.osm.pbf}"
                local file_name=$(basename "$base_name")
                
                log_progress "Processing ${file_name}"
                
                log_progress "Running osrm-extract on ${file_name}"
                /usr/local/bin/osrm-extract \
                    "${osm_file}" \
                    --profile "${profile_path}" \
                    --threads "$(nproc)" \
                    ${EXTRACT_EXTRA_ARGS:-} || handle_error "osrm-extract failed for ${file_name}"
                
                log_progress "Running osrm-contract on ${file_name}"
                /usr/local/bin/osrm-contract \
                    "${base_name}" \
                    --threads "$(nproc)" \
                    ${CONTRACT_EXTRA_ARGS:-} || handle_error "osrm-contract failed for ${file_name}"
                
                log_progress "Uploading ${file_name} files"
                for file in "${base_name}".osrm*; do
                    upload_s3_file "$file" "${OSRM_OUTPUT_DIR}/$(basename "$file")"
                done
                
                # Clean up to save space
                rm -f "${osm_file}" "${base_name}."*
            done
            
            log_progress "Pipeline completed for all files"
            ;;
            
        *)
            handle_error "Unknown operation: ${OSRM_OPERATION}"
            ;;
    esac
    
    log_progress "Operation ${OSRM_OPERATION} completed successfully"
}

# Execute main function
main "$@"
