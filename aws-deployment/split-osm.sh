#!/bin/bash
# Split an OSM file using poly files if they exist
# Returns array of files to process (either split files or just the input file)

split_osm() {
    local input_file="$1"
    local base_name="${input_file%.osm.pbf}"
    local region_name=$(basename "$base_name")
    
    # Find poly files for this region
    local poly_files=(/src/aws-deployment/config/${region_name}.*.poly)
    
    # If no poly files exist, return input file
    if [[ ! -f "${poly_files[0]}" ]]; then
        echo "$input_file"
        return 0
    fi
    
    log_progress "Found ${#poly_files[@]} poly files for splitting" >&2
    
    # Process each poly file
    local output_files=()
    for poly_file in "${poly_files[@]}"; do
        local name=$(basename "$poly_file" .poly)
        local output_file="/output/${name}.osm.pbf"
        
        log_progress "Extracting ${name} to /output" >&2
        osmosis --read-pbf "$input_file" \
                --bounding-polygon file="$poly_file" \
                --write-pbf "$output_file" \
                || handle_error "Failed to extract ${name}"
        
        output_files+=("$output_file")
    done
    
    # Return array of output files
    printf '%s\n' "${output_files[@]}"
}
