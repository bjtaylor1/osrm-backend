#!/bin/bash
set -euo pipefail

# Trap errors and log them before exiting
trap 'echo "$(date "+%Y-%m-%d %H:%M:%S") - FATAL ERROR at line $LINENO: Command failed with exit code $?" >&2' ERR

# Logging setup
exec > >(tee -a ${OSRM_LOG_DIR}/osrm-batch.log) 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting OSRM AWS Batch processing"
echo "Container ID: ${HOSTNAME}"
echo "AWS Region: ${AWS_DEFAULT_REGION:-not set}"
echo "Data directory: ${OSRM_DATA_DIR}"
echo "Output directory: ${OSRM_OUTPUT_DIR}"
echo "OSRM Operation: ${OSRM_OPERATION:-NOT SET}"

# Function to handle errors
handle_error() {
    local error_msg="$1"
    local line_no="${2:-unknown}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR at line ${line_no}: ${error_msg}" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Stack trace:" >&2
    local frame=0
    while caller $frame; do
        ((frame++))
    done
    exit 1
}

# Function to log progress
log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

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
            echo "  ✓ SPLIT_CONFIG: ${SPLIT_CONFIG:-not set}"
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
            local split_config="${SPLIT_CONFIG:-}"
            
            # Download OSM file
            download_file "${OSM_FILE}" "${osm_local_file}"
            
            # Validate profile exists
            [[ -f "${profile_path}" ]] || handle_error "Profile ${PROFILE}.lua not found"
            
            # Check if split config is provided
            if [[ -n "${split_config}" ]]; then
                log_progress "Split configuration provided, downloading: ${split_config}"
                
                # Download split config (supports S3 or HTTP)
                local split_config_file="${OSRM_DATA_DIR}/split-config.json"
                download_file "${split_config}" "${split_config_file}"
                
                # Get bounding box from OSM file for latitude bounds
                local bbox=$(osmium fileinfo -e -g data.bbox "${osm_local_file}" | grep -oP '(?<=\()[-0-9.,]+(?=\))')
                IFS=',' read -r osm_min_lon osm_min_lat osm_max_lon osm_max_lat <<< "$bbox"
                log_progress "OSM bounding box: lon(${osm_min_lon},${osm_max_lon}) lat(${osm_min_lat},${osm_max_lat})"
                
                # Parse and process each slice from config
                local num_slices=$(jq '.slices | length' "${split_config_file}")
                log_progress "Processing ${num_slices} slices from configuration"
                
                for i in $(seq 0 $((num_slices - 1))); do
                    local slice_name=$(jq -r ".slices[$i].name" "${split_config_file}")
                    local min_lon=$(jq -r ".slices[$i].minLongitude" "${split_config_file}")
                    local max_lon=$(jq -r ".slices[$i].maxLongitude" "${split_config_file}")
                    
                    log_progress "Processing ${slice_name}: lon(${min_lon},${max_lon})"
                    
                    # Extract slice using osmium
                    local slice_file="${OSRM_DATA_DIR}/${slice_name}.osm.pbf"
                    
                    # Handle dateline wrapping (when max < min, like slice_a: 116.5 to -98.5)
                    if (( $(echo "${max_lon} < ${min_lon}" | bc -l) )); then
                        log_progress "${slice_name} crosses dateline, extracting in two parts"
                        
                        # Extract part 1: min_lon to 180
                        local part1="${OSRM_DATA_DIR}/${slice_name}_part1.osm.pbf"
                        osmium extract \
                            --bbox "${min_lon},${osm_min_lat},180,${osm_max_lat}" \
                            -o "${part1}" \
                            "${osm_local_file}" || handle_error "Failed to extract ${slice_name} part 1"
                        
                        # Extract part 2: -180 to max_lon
                        local part2="${OSRM_DATA_DIR}/${slice_name}_part2.osm.pbf"
                        osmium extract \
                            --bbox "-180,${osm_min_lat},${max_lon},${osm_max_lat}" \
                            -o "${part2}" \
                            "${osm_local_file}" || handle_error "Failed to extract ${slice_name} part 2"
                        
                        # Merge the two parts
                        osmium merge "${part1}" "${part2}" -o "${slice_file}" || handle_error "Failed to merge ${slice_name} parts"
                        rm -f "${part1}" "${part2}"
                    else
                        osmium extract \
                            --bbox "${min_lon},${osm_min_lat},${max_lon},${osm_max_lat}" \
                            -o "${slice_file}" \
                            "${osm_local_file}" || handle_error "Failed to extract ${slice_name}"
                    fi
                    
                    # Run OSRM pipeline on slice
                    log_progress "Running osrm-extract on ${slice_name}"
                    /usr/local/bin/osrm-extract \
                        "${slice_file}" \
                        --profile "${profile_path}" \
                        --threads "$(nproc)" \
                        ${EXTRACT_EXTRA_ARGS:-} || handle_error "osrm-extract failed for ${slice_name}"
                    
                    log_progress "Running osrm-contract on ${slice_name}"
                    /usr/local/bin/osrm-contract \
                        "${OSRM_DATA_DIR}/${slice_name}" \
                        --threads "$(nproc)" \
                        ${CONTRACT_EXTRA_ARGS:-} || handle_error "osrm-contract failed for ${slice_name}"
                    
                    # Upload all OSRM files for this slice
                    log_progress "Uploading ${slice_name} files to S3"
                    for file in "${OSRM_DATA_DIR}/${slice_name}".osrm*; do
                        log_progress "Uploading $(basename "$file")"
                        upload_s3_file "$file" "${OSRM_OUTPUT_DIR}/$(basename "$file")"
                    done
                    
                    # Clean up slice files to save space
                    rm -f "${slice_file}" "${OSRM_DATA_DIR}/${slice_name}."*
                done
                
                log_progress "All ${num_slices} slices processed successfully"
            else
                log_progress "No split config, processing as single file"
                
                # Extract
                log_progress "Running osrm-extract with profile ${PROFILE}"
                /usr/local/bin/osrm-extract \
                    "${osm_local_file}" \
                    --profile "${profile_path}" \
                    --threads "$(nproc)" \
                    ${EXTRACT_EXTRA_ARGS:-} || handle_error "osrm-extract failed"
                
                # Contract - use /data/input (without .osrm extension)
                log_progress "Running osrm-contract on ${OSRM_DATA_DIR}/input"
                /usr/local/bin/osrm-contract \
                    "${OSRM_DATA_DIR}/input" \
                    --threads "$(nproc)" \
                    ${CONTRACT_EXTRA_ARGS:-} || handle_error "osrm-contract failed"
                                
                # Upload all OSRM files
                log_progress "Uploading files to S3"
                ls -lh "${OSRM_DATA_DIR}"
                for file in "${OSRM_DATA_DIR}"/input.osrm*; do
                    log_progress "Uploading $(basename "$file")"
                    upload_s3_file "$file" "${OSRM_OUTPUT_DIR}/$(basename "$file")"
                done
            fi
            ;;
            
        *)
            handle_error "Unknown operation: ${OSRM_OPERATION}"
            ;;
    esac
    
    log_progress "Operation ${OSRM_OPERATION} completed successfully"
}

# Execute main function
main "$@"
