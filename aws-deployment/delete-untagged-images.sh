#!/bin/bash

set -e

REPO_NAME="osrm-aws-batch"
REGION="us-east-1"

echo "Fetching untagged images..."
UNTAGGED_IMAGES=$(aws ecr list-images \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --filter tagStatus=UNTAGGED \
  --query 'imageIds[*]' \
  --output json)

if [ "$UNTAGGED_IMAGES" == "[]" ] || [ -z "$UNTAGGED_IMAGES" ]; then
  echo "No untagged images to delete"
  exit 0
fi

echo "Attempting to delete untagged images..."
DELETE_RESULT=$(aws ecr batch-delete-image \
  --repository-name "$REPO_NAME" \
  --region "$REGION" \
  --image-ids "$UNTAGGED_IMAGES" \
  --output json)

echo "$DELETE_RESULT"

# Check for failures due to manifest lists
FAILED_MANIFESTS=$(echo "$DELETE_RESULT" | jq -r '.failures[] | select(.failureCode == "ImageReferencedByManifestList") | .failureReason' | grep -oE 'sha256:[a-f0-9]+' || true)

if [ -n "$FAILED_MANIFESTS" ]; then
  echo ""
  echo "Some images are referenced by manifest lists. Attempting to delete manifest lists first..."
  
  # Get unique manifest list digests
  MANIFEST_DIGESTS=$(echo "$FAILED_MANIFESTS" | sort -u)
  
  for DIGEST in $MANIFEST_DIGESTS; do
    echo "Deleting manifest list: $DIGEST"
    aws ecr batch-delete-image \
      --repository-name "$REPO_NAME" \
      --region "$REGION" \
      --image-ids imageDigest="$DIGEST" || echo "Failed to delete manifest list $DIGEST"
  done
  
  echo ""
  echo "Retrying deletion of remaining untagged images..."
  # Re-fetch untagged images in case the manifest list deletion changed tagging status
  REMAINING_UNTAGGED=$(aws ecr list-images \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --filter tagStatus=UNTAGGED \
    --query 'imageIds[*]' \
    --output json)
  
  if [ "$REMAINING_UNTAGGED" != "[]" ] && [ -n "$REMAINING_UNTAGGED" ]; then
    aws ecr batch-delete-image \
      --repository-name "$REPO_NAME" \
      --region "$REGION" \
      --image-ids "$REMAINING_UNTAGGED" || echo "Some images may still be referenced"
  else
    echo "No remaining untagged images to delete"
  fi
fi

echo ""
echo "Cleanup complete!"
