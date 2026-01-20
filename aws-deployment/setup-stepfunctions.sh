#!/bin/bash
set -e

SCRIPT_DIR=$(dirname "$0")
ACCOUNT_ID=259514351789
export AWS_PAGER=""

if ! aws iam get-role --role-name lambda-osrm-role 2>/dev/null; then
  aws iam create-role --role-name lambda-osrm-role --assume-role-policy-document file://$SCRIPT_DIR/lambda-trust-policy.json
  aws iam attach-role-policy --role-name lambda-osrm-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam put-role-policy --role-name lambda-osrm-role --policy-name lambda-osrm-permissions --policy-document file://$SCRIPT_DIR/lambda-permissions-policy.json
  sleep 10
fi

if ! aws iam get-role --role-name stepfunctions-osrm-role 2>/dev/null; then
  aws iam create-role --role-name stepfunctions-osrm-role --assume-role-policy-document file://$SCRIPT_DIR/stepfunctions-trust-policy.json
  aws iam put-role-policy --role-name stepfunctions-osrm-role --policy-name stepfunctions-osrm-permissions --policy-document file://$SCRIPT_DIR/stepfunctions-permissions-policy.json
  sleep 10
fi

if aws lambda get-function --function-name osrm-deploy-server 2>/dev/null; then
  aws lambda update-function-code --function-name osrm-deploy-server --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-deploy-server.py deploy-server.startup-script.sh)
else
  aws lambda create-function --function-name osrm-deploy-server --runtime python3.12 --role arn:aws:iam::$ACCOUNT_ID:role/lambda-osrm-role --handler osrm-deploy-server.lambda_handler --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-deploy-server.py deploy-server.startup-script.sh) --timeout 300 --region us-east-1
fi

if aws lambda get-function --function-name osrm-register-instance 2>/dev/null; then
  aws lambda update-function-code --function-name osrm-register-instance --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-register-instance.py)
else
  aws lambda create-function --function-name osrm-register-instance --runtime python3.12 --role arn:aws:iam::$ACCOUNT_ID:role/lambda-osrm-role --handler osrm-register-instance.lambda_handler --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-register-instance.py) --timeout 300 --region us-east-1
fi

if aws lambda get-function --function-name osrm-check-instance-health 2>/dev/null; then
  aws lambda update-function-code --function-name osrm-check-instance-health --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-check-instance-health.py)
else
  aws lambda create-function --function-name osrm-check-instance-health --runtime python3.12 --role arn:aws:iam::$ACCOUNT_ID:role/lambda-osrm-role --handler osrm-check-instance-health.lambda_handler --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-check-instance-health.py) --timeout 60 --region us-east-1
fi

if aws lambda get-function --function-name osrm-swap-instances 2>/dev/null; then
  aws lambda update-function-code --function-name osrm-swap-instances --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-swap-instances.py)
else
  aws lambda create-function --function-name osrm-swap-instances --runtime python3.12 --role arn:aws:iam::$ACCOUNT_ID:role/lambda-osrm-role --handler osrm-swap-instances.lambda_handler --zip-file fileb://<(cd $SCRIPT_DIR && zip -q -r - osrm-swap-instances.py) --timeout 60 --region us-east-1
fi

if aws stepfunctions describe-state-machine --state-machine-arn arn:aws:states:us-east-1:$ACCOUNT_ID:stateMachine:osrm-deployment-pipeline 2>/dev/null; then
  aws stepfunctions update-state-machine --state-machine-arn arn:aws:states:us-east-1:$ACCOUNT_ID:stateMachine:osrm-deployment-pipeline --definition file://$SCRIPT_DIR/stepfunction-definition.json
else
  aws stepfunctions create-state-machine --name osrm-deployment-pipeline --definition file://$SCRIPT_DIR/stepfunction-definition.json --role-arn arn:aws:iam::$ACCOUNT_ID:role/stepfunctions-osrm-role --region us-east-1
fi
