#!/bin/bash
MODE=$1

case $MODE in
  test)
    INPUT='{
      "mode": "test",
      "job_name": "process-monaco-direct-data",
      "job_queue": "job-queue-r6i-large",
      "job_definition": "osrm-direct-processor-job-small",
      "environment": [
        {"name": "OSM_SOURCE", "value": "https://download.geofabrik.de/europe/monaco-latest.osm.pbf"},
        {"name": "OSM_FILE", "value": "monaco-latest"},
        {"name": "PROFILE", "value": "bicycle_paved"}
      ],
      "router_region": "monaco-latest"
    }'
    ;;
  prod)
    INPUT='{
      "mode": "prod",
      "job_name": "process-planet-direct-data",
      "job_queue": "job-queue-r5d-16xlarge",
      "job_definition": "osrm-direct-processor-job",
      "environment": [
        {"name": "OSM_SOURCE", "value": "https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf"},
        {"name": "OSM_FILE", "value": "planet-latest"},
        {"name": "PROFILE", "value": "bicycle_paved"}
      ],
      "router_region": "planet-latest"
    }'
    ;;
  deploy-only)
    INPUT='{
      "mode": "deploy-only",
      "router_region": "planet-latest"
    }'
    ;;
  *)
    echo "Usage: $0 {test|prod|deploy-only}"
    exit 1
    ;;
esac

aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:259514351789:stateMachine:osrm-deployment-pipeline \
  --input "$INPUT" \
  --region us-east-1
