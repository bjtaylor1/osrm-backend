#!/bin/bash
# Apply IAM policy to gpxeditoradmin user
# Run this with root credentials: AWS_PROFILE=root ./apply-iam-policy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${SCRIPT_DIR}/iam-policy-gpxeditoradmin.json"
USER_NAME="gpxeditoradmin"
POLICY_NAME="OSRMDeploymentPolicy"

echo "Creating managed IAM policy: ${POLICY_NAME}"

# Create the managed policy
POLICY_ARN=$(aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document "file://${POLICY_FILE}" \
    --description "Permissions for OSRM AWS Batch deployment and EC2 server management" \
    --query 'Policy.Arn' \
    --output text 2>/dev/null || \
    aws iam list-policies \
        --scope Local \
        --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
        --output text)

echo "Policy ARN: ${POLICY_ARN}"

# Attach policy to user
echo "Attaching policy to user: ${USER_NAME}"
aws iam attach-user-policy \
    --user-name "${USER_NAME}" \
    --policy-arn "${POLICY_ARN}"

echo "✓ Policy attached successfully!"
echo ""
echo "To verify permissions:"
echo "  aws iam list-attached-user-policies --user-name ${USER_NAME}"
