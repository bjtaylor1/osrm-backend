# OSRM Step Function Deployment Guide

## Overview

This guide explains how to use the OSRM deployment pipeline Step Function and how to maintain its integrity when making modifications.

## Step Function Components

The OSRM deployment pipeline consists of several interconnected files that must be kept in sync:

### Core Files
1. **stepfunction-definition.json** - The Step Function state machine definition
2. **setup-stepfunctions.sh** - Deployment script that creates/updates Lambda functions and Step Function
3. **stepfunctions-permissions-policy.json** - IAM policy for Step Function execution role
4. **stepfunctions-trust-policy.json** - Trust policy allowing Step Functions service to assume the role
5. **lambda-permissions-policy.json** - IAM policy for Lambda execution role
6. **lambda-trust-policy.json** - Trust policy allowing Lambda service to assume the role

### Lambda Function Files
1. **osrm-deploy-server.py** - Deploys a new EC2 instance with OSRM
2. **osrm-register-instance.py** - Registers the instance with the load balancer target group
3. **osrm-check-instance-health.py** - Checks if the instance is healthy in the target group
4. **osrm-swap-instances.py** - Deregisters and terminates old instances
5. **osrm_utils.py** - Shared utilities used by multiple Lambda functions
6. **deploy-server.startup-script.sh** - Startup script for EC2 instances

## Executing the Step Function

### Required Parameters

When starting a Step Function execution, you must provide the following input:

```json
{
  "target_group_name": "RouterTargetGroup",
  "router_region": "europe",
  "mode": "deploy-only"
}
```

Or for full processing + deployment:

```json
{
  "target_group_name": "RouterTargetGroup",
  "router_region": "europe",
  "job_name": "process-planet",
  "job_queue": "osrm-processing-queue",
  "job_definition": "osrm-process-data",
  "environment": [
    {
      "name": "S3_BUCKET",
      "value": "osrm-data-bucket"
    },
    {
      "name": "REGION",
      "value": "europe"
    }
  ]
}
```

### Parameter Descriptions

- **target_group_name** (required): Name of the Application Load Balancer target group where instances will be registered. The Step Function will look up the ARN dynamically and validate that exactly one target group exists with this name.

- **router_region** (required): The geographic region identifier for the OSRM router (e.g., "europe", "north-america").

- **mode** (optional): 
  - `"deploy-only"`: Skip batch processing and go directly to deploying a server
  - Omit or use other value: Run batch processing first, then deploy

- **job_name**, **job_queue**, **job_definition**, **environment** (required if mode != "deploy-only"): AWS Batch job configuration for processing OSM data.

### Execution via AWS CLI

```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:259514351789:stateMachine:osrm-deployment-pipeline \
  --input '{"target_group_name":"RouterTargetGroup","router_region":"europe","mode":"deploy-only"}'
```

### Execution via AWS Console

1. Open the AWS Step Functions console
2. Select the `osrm-deployment-pipeline` state machine
3. Click "Start execution"
4. Paste the JSON input in the input field
5. Click "Start execution"

## Step Function Flow

1. **CheckMode**: Determines whether to run batch processing or deploy directly
2. **SubmitBatchJob** (optional): Submits AWS Batch job to process OSM data
3. **DeployServer**: Creates a new EC2 instance with OSRM
4. **RegisterInstance**: Registers the new instance with the target group
5. **CheckInstanceHealth**: Checks if the instance is healthy
6. **IsHealthy**: Decision point - retry health check or proceed
7. **WaitForHealth**: Wait 30 seconds before retrying health check
8. **SwapInstances**: Deregister and terminate old instances

## Maintaining Step Function Integrity

When modifying the Step Function or Lambda functions, ensure you maintain integrity across all files:

### Adding a New Parameter

1. **Update Lambda Function(s)**:
   - Modify the relevant `.py` file(s) to accept the new parameter from `event`
   - Add appropriate validation and error handling

2. **Update stepfunction-definition.json**:
   - Add the parameter to the relevant Lambda invocation's `Payload` section
   - Use JSONPath notation (e.g., `"param_name.$": "$.param_name"`) to pass from Step Function input

3. **Update Permissions** (if needed):
   - If the new parameter requires access to new AWS services, update `lambda-permissions-policy.json`
   - If Step Function needs new permissions, update `stepfunctions-permissions-policy.json`

4. **Update setup-stepfunctions.sh** (if needed):
   - If adding new Lambda functions, add create/update blocks
   - If adding new dependencies, update the zip file contents

5. **Test**:
   - Run `./setup-stepfunctions.sh` to deploy changes
   - Execute Step Function with test input
   - Verify all states execute correctly

### Adding a New Lambda Function

1. **Create the Lambda Function**:
   - Create new `.py` file in `aws-deployment/`
   - Import shared utilities from `osrm_utils.py` if needed
   - Implement `lambda_handler(event, context)` function

2. **Update setup-stepfunctions.sh**:
   - Add create/update block for the new function
   - Include all necessary files in the zip package

3. **Update stepfunction-definition.json**:
   - Add new state(s) for the Lambda function
   - Wire up state transitions correctly

4. **Update Permissions**:
   - Add any required AWS service permissions to `lambda-permissions-policy.json`
   - Update Step Function permissions if needed

### Adding a New Shared Utility

1. **Update osrm_utils.py**:
   - Add the new utility function with proper documentation

2. **Update setup-stepfunctions.sh**:
   - Ensure `osrm_utils.py` is included in the zip for all Lambda functions that need it
   - Format: `zip -q -r - function.py osrm_utils.py`

### Modifying IAM Permissions

1. **Lambda Permissions** (`lambda-permissions-policy.json`):
   - Add actions/resources needed by Lambda functions
   - Keep permissions as restrictive as possible

2. **Step Function Permissions** (`stepfunctions-permissions-policy.json`):
   - Add permissions for invoking new Lambda functions
   - Add permissions for new AWS service integrations

3. **Apply Changes**:
   - Run `./setup-stepfunctions.sh` to update IAM policies

## Common Operations

### Deploying Changes

After modifying any files:

```bash
cd aws-deployment
./setup-stepfunctions.sh
```

This script will:
- Create or update IAM roles and policies
- Create or update all Lambda functions
- Create or update the Step Function state machine

### Viewing Execution History

```bash
# List recent executions
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:us-east-1:259514351789:stateMachine:osrm-deployment-pipeline \
  --max-results 10

# Get execution details
aws stepfunctions describe-execution \
  --execution-arn <execution-arn>

# Get execution history
aws stepfunctions get-execution-history \
  --execution-arn <execution-arn>
```

### Debugging Failed Executions

1. Check execution events in AWS Console or via CLI
2. Check Lambda CloudWatch Logs for specific function failures
3. Verify input parameters match expected schema
4. Check IAM permissions if seeing access denied errors

## Target Group Configuration

The Step Function now dynamically looks up the target group ARN from its name. This provides several benefits:

- No hardcoded ARNs in the code
- Easy to switch between different target groups
- Automatic validation that the target group exists and is unique
- Centralized error handling in `osrm_utils.py`

The target group must:
- Exist in the us-east-1 region
- Have a unique name (no duplicates)
- Be configured to accept traffic on the appropriate port (typically 5000 for OSRM)

## Troubleshooting

### "Target group not found" Error

- Verify the target group exists: `aws elbv2 describe-target-groups --names RouterTargetGroup`
- Check the region matches (us-east-1)
- Verify spelling of target group name in input

### "Multiple target groups found" Error

- Check for duplicate target groups: `aws elbv2 describe-target-groups`
- Rename or delete duplicate target groups
- Ensure target group names are unique

### Lambda Function Timeout

- Check CloudWatch Logs for the specific function
- Increase timeout in `setup-stepfunctions.sh` if needed
- Current timeouts: deploy-server (300s), register-instance (300s), others (60s)

### Permission Errors

- Verify IAM policies are up to date
- Check trust relationships allow the correct services
- Ensure Step Function role can invoke Lambda functions
- Ensure Lambda role can access required AWS services

## Best Practices

1. **Always test changes** in a development environment first
2. **Version control** all changes to Step Function files
3. **Document** any new parameters or states added
4. **Keep permissions minimal** - only grant what's necessary
5. **Use CloudWatch** Logs and X-Ray for debugging
6. **Validate input** in Lambda functions before processing
7. **Handle errors gracefully** with appropriate error messages
8. **Monitor executions** regularly for failures
9. **Keep shared utilities** (like `osrm_utils.py`) well-documented and tested
10. **Update this guide** when making significant changes to the Step Function
