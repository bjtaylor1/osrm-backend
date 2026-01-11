#!/bin/bash
set -e

ROLE_NAME="OSRM-Instance-Role"
INSTANCE_PROFILE_NAME="OSRM-Instance-Profile"

echo "Creating IAM role for EC2 instances to access S3 and EC2 metadata..."

# Create role if it doesn't exist
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    echo "IAM role $ROLE_NAME already exists"
else
    echo "Creating IAM role: $ROLE_NAME"
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file://trust-policy.json
fi

# Attach S3 read policy if not already attached
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess']" --output text | grep -q "AmazonS3ReadOnlyAccess"; then
    echo "S3 read-only policy already attached to role"
else
    echo "Attaching S3 read-only policy to role..."
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
fi

# Attach EC2 read policy if not already attached
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess']" --output text | grep -q "AmazonEC2ReadOnlyAccess"; then
    echo "EC2 read-only policy already attached to role"
else
    echo "Attaching EC2 read-only policy to role..."
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess
fi

# Create instance profile if it doesn't exist
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
    echo "Instance profile $INSTANCE_PROFILE_NAME already exists"
else
    echo "Creating instance profile: $INSTANCE_PROFILE_NAME"
    aws iam create-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME"
fi

# Add role to instance profile if not already added
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --query "InstanceProfile.Roles[?RoleName=='$ROLE_NAME']" --output text | grep -q "$ROLE_NAME"; then
    echo "Role $ROLE_NAME already attached to instance profile"
else
    echo "Adding role to instance profile..."
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$ROLE_NAME"
fi

echo ""
echo "✓ IAM role and instance profile created successfully!"
echo ""
echo "Role $ROLE_NAME now has the following policies attached:"
echo "  - AmazonS3ReadOnlyAccess (for S3 operations)"
echo "  - AmazonEC2ReadOnlyAccess (for EC2 metadata/describe operations)"
echo ""
echo "To use in deploy-server.sh, add this line:"
echo "    --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \\"
echo ""
echo "Note: If you need write access to S3, replace AmazonS3ReadOnlyAccess with AmazonS3FullAccess"
