#!/bin/bash
set -euo pipefail

trap 'echo "$(date "+%Y-%m-%d %H:%M:%S") - FATAL ERROR at line $LINENO: Command failed with exit code $?" >&2' ERR

exec > >(tee -a /logs/split-test.log) 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting OSRM Split Testing"

handle_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2
    exit 1
}

log_progress() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Source the split function
source /split-osm.sh

main() {
    local osm_local_file="/data/$INPUT_FILE"
    [[ -f "$osm_local_file" ]] || handle_error "$osm_local_file not found"
    
    log_progress "Found $osm_local_file ($(du -h "$osm_local_file" | cut -f1))"
    
    # Split the file (returns array of files - either splits or just the input)
    mapfile -t files_to_process < <(split_osm "$osm_local_file")
    
    log_progress "Split complete: ${#files_to_process[@]} file(s) created"
    for file in "${files_to_process[@]}"; do
        log_progress "$file => ($(du -h "$file" | cut -f1))"
    done
}

main "$@"

