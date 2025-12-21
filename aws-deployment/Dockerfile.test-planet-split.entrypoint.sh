#!/bin/bash
set -euo pipefail

# Trap errors and log them before exiting
trap 'echo "$(date "+%Y-%m-%d %H:%M:%S") - FATAL ERROR at line $LINENO: Command failed with exit code $?" >&2' ERR

# Logging setup
exec > >(tee -a ${OSRM_LOG_DIR}/split-test.log) 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting OSRM Split Testing"
echo "Container ID: ${HOSTNAME}"
echo "AWS Region: ${AWS_DEFAULT_REGION:-not set}"
echo "Data directory: ${OSRM_DATA_DIR}"
echo "Output directory: ${OSRM_OUTPUT_DIR}"

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
        wget --no-verbose -O "$local_path" "$remote_path" || handle_error "Failed to download $remote_path"
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
        log_progress "Skipping upload (not an S3 path): $s3_path"
    fi
}

# Main function
main() {
    # Verify planet-latest.osm.pbf exists in /data
    local osm_local_file="${OSRM_DATA_DIR}/planet-latest.osm.pbf"
    [[ -f "${osm_local_file}" ]] || handle_error "planet-latest.osm.pbf not found in ${OSRM_DATA_DIR}"
    
    log_progress "Found planet-latest.osm.pbf at ${osm_local_file}"
    
    # Get file size
    local file_size=$(du -h "${osm_local_file}" | cut -f1)
    log_progress "Planet file size: ${file_size}"
    
    # Verify SPLIT_CONFIG is provided
    [[ -n "${SPLIT_CONFIG:-}" ]] || handle_error "SPLIT_CONFIG environment variable not set"
    
    log_progress "Split configuration: ${SPLIT_CONFIG}"
    
    # Download split config (supports S3 or HTTP)
    local split_config_file="${OSRM_DATA_DIR}/split-config.json"
    download_file "${SPLIT_CONFIG}" "${split_config_file}"
    
    # Get bounding box from OSM file for latitude bounds
    log_progress "Analyzing planet file bounding box..."
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
        
        # Get size of extracted slice
        local slice_size=$(du -h "${slice_file}" | cut -f1)
        log_progress "Extracted ${slice_name} (size: ${slice_size})"
        
        # Upload slice to S3 if OUTPUT_DIR is S3
        if [[ "${OSRM_OUTPUT_DIR}" == s3://* ]]; then
            log_progress "Uploading ${slice_name} to S3"
            upload_s3_file "${slice_file}" "${OSRM_OUTPUT_DIR}/$(basename "${slice_file}")"
            
            # Clean up slice file after upload to save space
            rm -f "${slice_file}"
            log_progress "Cleaned up ${slice_name} after upload"
        else
            log_progress "Keeping ${slice_name} in ${OSRM_DATA_DIR} (not uploading to S3)"
        fi
    done
    
    log_progress "All ${num_slices} slices processed successfully"
    log_progress "Split operation completed"
}

# Execute main function
main "$@"
