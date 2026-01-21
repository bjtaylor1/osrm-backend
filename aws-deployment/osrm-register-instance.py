#!/usr/bin/env python3
import boto3
from osrm_utils import get_target_group_arn

ec2 = boto3.client('ec2', region_name='us-east-1')  # For waiter only
elbv2 = boto3.client('elbv2', region_name='us-east-1')


def lambda_handler(event, context):
    instance_id = event['instance_id']
    target_group_name = event['target_group_name']
    
    # Look up the target group ARN from its name
    target_group_arn = get_target_group_arn(target_group_name)
    
    ec2.get_waiter('instance_running').wait(InstanceIds=[instance_id])
    
    # Register instance with target group
    # No need to modify security group - instance was created with 'allow-http-from-load-balancer' security group
    elbv2.register_targets(TargetGroupArn=target_group_arn, Targets=[{'Id': instance_id}])
    return {'instance_id': instance_id}

if __name__ == '__main__':
    import sys
    result = lambda_handler({'instance_id': sys.argv[1]}, None)
    print(result)
