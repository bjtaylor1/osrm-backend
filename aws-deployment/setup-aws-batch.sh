#!/bin/bash

# AWS Batch OSRM Setup Script
# This script helps set up OSRM for AWS Batch processing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}" && pwd)"

# Default values
IMAGE_NAME="osrm-aws-batch"
IMAGE_TAG="latest"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ECR_REGISTRY=""
BUILD_CONCURRENCY="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

show_help() {
    cat << 'EOF'
OSRM AWS Batch Setup Script

Usage: ./setup-aws-batch.sh [OPTIONS] COMMAND

COMMANDS:
    build               Build the Docker image locally
    push                Push image to ECR (requires ECR_REGISTRY)
    create-ecr          Create ECR repository
    build-and-push      Build and push image to ECR
    create-job-def      Create AWS Batch job definition
    create-queue        Create AWS Batch job queue and compute environment
    setup-full          Complete setup (ECR + Job Definition + Queue)
    test-local          Test the image locally
    clean               Clean up local images

OPTIONS:
    -n, --name NAME         Image name (default: osrm-aws-batch)
    -t, --tag TAG          Image tag (default: latest)
    -r, --registry REG     ECR registry URL
    -j, --job-name NAME    AWS Batch job definition name
    -q, --queue-name NAME  AWS Batch job queue name
    -c, --compute-env NAME Compute environment name
    --region REGION        AWS region (default: us-east-1)
    --vcpus NUM           vCPUs for compute environment (default: 4)
    --memory MB           Memory for compute environment (default: 8192)
    --instance-types LIST Instance types (default: m5.large,m5.xlarge,c5.large,c5.xlarge)
    -h, --help            Show this help

EXAMPLES:
    # Build image locally
    ./setup-aws-batch.sh build

    # Full setup with custom names
    ./setup-aws-batch.sh -r 123456789012.dkr.ecr.us-east-1.amazonaws.com -j osrm-job -q osrm-queue setup-full

    # Test locally
    ./setup-aws-batch.sh test-local
EOF
}

# Parse command line arguments
COMMAND=""
JOB_DEFINITION_NAME="osrm-batch-job"
QUEUE_NAME="osrm-batch-queue"
COMPUTE_ENV_NAME="osrm-batch-compute-env"
VCPUS="4"
MEMORY="8192"
INSTANCE_TYPES="m5.large,m5.xlarge,c5.large,c5.xlarge"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -t|--tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        -r|--registry)
            ECR_REGISTRY="$2"
            shift 2
            ;;
        -j|--job-name)
            JOB_DEFINITION_NAME="$2"
            shift 2
            ;;
        -q|--queue-name)
            QUEUE_NAME="$2"
            shift 2
            ;;
        -c|--compute-env)
            COMPUTE_ENV_NAME="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --vcpus)
            VCPUS="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --instance-types)
            INSTANCE_TYPES="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option $1"
            show_help
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

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# Check if AWS CLI is available
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        error "AWS CLI not found. Please install AWS CLI and configure credentials."
    fi
}

# Check if Docker is available and running
check_docker() {
    if ! command -v docker &> /dev/null; then
        error "Docker not found. Please install Docker."
    fi
    
    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon not running. Please start Docker."
    fi
}

# Build the Docker image
build_image() {
    log "Building OSRM AWS Batch image: ${IMAGE_NAME}:${IMAGE_TAG}"
    
    cd "${PROJECT_ROOT}"
    
    docker build \
        -f Dockerfile.aws-batch \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        --build-arg BUILD_CONCURRENCY="${BUILD_CONCURRENCY}" \
        --build-arg CMAKE_BUILD_TYPE=Release \
        . || error "Failed to build Docker image"
    
    log "Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
}

# Create ECR repository
create_ecr_repo() {
    check_aws_cli
    
    log "Creating ECR repository: ${IMAGE_NAME}"
    
    # Check if repository already exists
    if aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "${AWS_REGION}" &>/dev/null; then
        log "ECR repository already exists: ${IMAGE_NAME}"
    else
        # Try to create repository
        log "Repository doesn't exist, creating new ECR repository..."
        if ! aws ecr create-repository \
            --repository-name "${IMAGE_NAME}" \
            --region "${AWS_REGION}" \
            --image-scanning-configuration scanOnPush=true 2>&1; then
            error "Failed to create ECR repository. Check that you have ECR permissions (ecr:CreateRepository). Run: aws ecr describe-repositories --region ${AWS_REGION} to test."
        fi
        log "✓ ECR repository created successfully"
    fi
    
    # Get repository URI
    ECR_REGISTRY=$(aws ecr describe-repositories \
        --repository-names "${IMAGE_NAME}" \
        --region "${AWS_REGION}" \
        --query 'repositories[0].repositoryUri' \
        --output text)
    
    if [[ -z "$ECR_REGISTRY" ]]; then
        error "Failed to get ECR repository URI. Something went wrong."
    fi
    
    log "✓ ECR repository URI: ${ECR_REGISTRY}"
}

# Push image to ECR
push_image() {
    check_aws_cli
    check_docker
    
    if [[ -z "$ECR_REGISTRY" ]]; then
        error "ECR_REGISTRY not set. Use -r option or create ECR repository first."
    fi
    
    log "Pushing image to ECR: ${ECR_REGISTRY}:${IMAGE_TAG}"
    
    # Login to ECR
    log "Authenticating with ECR..."
    if ! aws ecr get-login-password --region "${AWS_REGION}" | \
        docker login --username AWS --password-stdin "${ECR_REGISTRY%/*}" 2>&1; then
        error "Failed to authenticate with ECR. Check AWS credentials and ECR permissions."
    fi
    log "✓ Authenticated with ECR"
    
    # Tag and push image
    log "Tagging image..."
    if ! docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${ECR_REGISTRY}:${IMAGE_TAG}"; then
        error "Failed to tag Docker image"
    fi
    
    log "Pushing image to ECR (this may take several minutes)..."
    if ! docker push "${ECR_REGISTRY}:${IMAGE_TAG}" 2>&1; then
        error "Failed to push image to ECR. Check network connection and ECR permissions."
    fi
    
    log "✓ Image pushed successfully: ${ECR_REGISTRY}:${IMAGE_TAG}"
}

# Create AWS Batch job definition
create_job_definition() {
    check_aws_cli
    
    if [[ -z "$ECR_REGISTRY" ]]; then
        error "ECR_REGISTRY not set. Use -r option or create ECR repository first."
    fi
    
    log "Creating AWS Batch job definition: ${JOB_DEFINITION_NAME}"
    
    cat > /tmp/job-definition.json << EOF
{
    "jobDefinitionName": "${JOB_DEFINITION_NAME}",
    "type": "container",
    "containerProperties": {
        "image": "${ECR_REGISTRY}:${IMAGE_TAG}",
        "vcpus": ${VCPUS},
        "memory": ${MEMORY},
        "jobRoleArn": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AWSBatchServiceRole",
        "environment": [
            {
                "name": "AWS_DEFAULT_REGION",
                "value": "${AWS_REGION}"
            }
        ],
        "mountPoints": [],
        "volumes": [],
        "ulimits": [
            {
                "name": "nofile",
                "hardLimit": 65536,
                "softLimit": 65536
            }
        ]
    },
    "retryStrategy": {
        "attempts": 3
    },
    "timeout": {
        "attemptDurationSeconds": 7200
    }
}
EOF
    
    if ! aws batch register-job-definition \
        --cli-input-json file:///tmp/job-definition.json \
        --region "${AWS_REGION}" 2>&1; then
        rm /tmp/job-definition.json
        error "Failed to create AWS Batch job definition. Check that you have Batch permissions (batch:RegisterJobDefinition)."
    fi
    
    rm /tmp/job-definition.json
    log "✓ Job definition created: ${JOB_DEFINITION_NAME}"
}

# Create compute environment and job queue
create_queue() {
    check_aws_cli
    
    log "Creating compute environment: ${COMPUTE_ENV_NAME}"
    
    # Get subnet and security group
    log "Finding default VPC subnet and security group..."
    SUBNET_ID=$(aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text 2>&1)
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
        error "No subnets found. You need a VPC with at least one subnet. Check AWS console."
    fi
    
    SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text 2>&1)
    if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
        error "No default security group found. Check your VPC configuration."
    fi
    
    log "Using subnet: ${SUBNET_ID}, security group: ${SG_ID}"
    
    # Check if compute environment already exists
    local existing_status=$(aws batch describe-compute-environments \
        --compute-environments "${COMPUTE_ENV_NAME}" \
        --region "${AWS_REGION}" \
        --query 'computeEnvironments[0].status' \
        --output text 2>/dev/null)
    
    if [[ -n "$existing_status" && "$existing_status" != "None" ]]; then
        log "Compute environment already exists with status: ${existing_status}"
    else
        # Create compute environment
        log "Creating new compute environment..."
        if ! aws batch create-compute-environment \
            --compute-environment-name "${COMPUTE_ENV_NAME}" \
            --type MANAGED \
            --state ENABLED \
            --compute-resources type=EC2,minvCpus=0,maxvCpus=256,desiredvCpus=0,instanceTypes="${INSTANCE_TYPES}",subnets="${SUBNET_ID}",securityGroupIds="${SG_ID}" \
            --region "${AWS_REGION}" 2>&1; then
            error "Failed to create compute environment. Check that you have Batch and EC2 permissions."
        fi
        log "✓ Compute environment creation initiated"
    fi
    
    # Wait for compute environment to be ready (manual polling since wait command not available in all AWS CLI versions)
    log "Waiting for compute environment to be ready (may take 30-60 seconds)..."
    local max_attempts=30
    local attempt=0
    local status=""
    
    while [ $attempt -lt $max_attempts ]; do
        status=$(aws batch describe-compute-environments \
            --compute-environments "${COMPUTE_ENV_NAME}" \
            --region "${AWS_REGION}" \
            --query 'computeEnvironments[0].status' \
            --output text 2>&1)
        
        if [[ "$status" == "VALID" ]]; then
            log "✓ Compute environment is ready"
            break
        elif [[ "$status" == "INVALID" ]]; then
            local reason=$(aws batch describe-compute-environments \
                --compute-environments "${COMPUTE_ENV_NAME}" \
                --region "${AWS_REGION}" \
                --query 'computeEnvironments[0].statusReason' \
                --output text 2>&1)
            error "Compute environment is INVALID. Reason: ${reason}"
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo -n "."
            sleep 2
        fi
    done
    
    if [[ "$status" != "VALID" ]]; then
        error "Compute environment did not become ready after ${max_attempts} attempts. Current status: ${status}. Check AWS Batch console."
    fi
    
    # Check if job queue already exists
    if aws batch describe-job-queues --job-queues "${QUEUE_NAME}" --region "${AWS_REGION}" --query 'jobQueues[0]' --output text &>/dev/null; then
        log "Job queue already exists: ${QUEUE_NAME}"
    else
        log "Creating job queue: ${QUEUE_NAME}"
        # Create job queue
        if ! aws batch create-job-queue \
            --job-queue-name "${QUEUE_NAME}" \
            --state ENABLED \
            --priority 1 \
            --compute-environment-order order=1,computeEnvironment="${COMPUTE_ENV_NAME}" \
            --region "${AWS_REGION}" 2>&1; then
            error "Failed to create job queue. Check Batch permissions."
        fi
        log "✓ Job queue created"
    fi
    
    log "✓ Job queue ready: ${QUEUE_NAME}"
}

# Test image locally
test_local() {
    check_docker
    
    log "Testing OSRM AWS Batch image locally"
    
    # Test help
    docker run --rm "${IMAGE_NAME}:${IMAGE_TAG}" \
        /scripts/osrm-batch.sh help
    
    # Test binary availability
    docker run --rm "${IMAGE_NAME}:${IMAGE_TAG}" \
        /usr/local/bin/osrm-extract --help | head -5
    
    log "Local test completed successfully"
}

# Clean up local images
clean_images() {
    check_docker
    
    log "Cleaning up local Docker images"
    
    docker rmi "${IMAGE_NAME}:${IMAGE_TAG}" 2>/dev/null || true
    docker system prune -f
    
    log "Cleanup completed"
}

# Execute command
case "$COMMAND" in
    build)
        check_docker
        build_image
        ;;
    push)
        push_image
        ;;
    create-ecr)
        create_ecr_repo
        ;;
    build-and-push)
        check_docker
        build_image
        if [[ -z "$ECR_REGISTRY" ]]; then
            create_ecr_repo
        fi
        push_image
        ;;
    create-job-def)
        create_job_definition
        ;;
    create-queue)
        create_queue
        ;;
    setup-full)
        check_docker
        check_aws_cli
        build_image
        if [[ -z "$ECR_REGISTRY" ]]; then
            create_ecr_repo
        fi
        push_image
        create_job_definition
        create_queue
        log "Full setup completed successfully!"
        log "Job Definition: ${JOB_DEFINITION_NAME}"
        log "Job Queue: ${QUEUE_NAME}"
        log "Image: ${ECR_REGISTRY}:${IMAGE_TAG}"
        ;;
    test-local)
        test_local
        ;;
    clean)
        clean_images
        ;;
    *)
        echo "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac