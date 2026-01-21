#!/usr/bin/env python3
import boto3
from osrm_utils import get_target_group_arn

ec2 = boto3.client('ec2', region_name='us-east-1')
elbv2 = boto3.client('elbv2', region_name='us-east-1')


def lambda_handler(event, context):
    instance_id = event['instance_id']
    target_group_name = event['target_group_name']
    
    # Look up the target group ARN from its name
    target_group_arn = get_target_group_arn(target_group_name)
    
    # Deregister old instances and terminate them
    current_targets = elbv2.describe_target_health(TargetGroupArn=target_group_arn)['TargetHealthDescriptions']
    old_instances = [t['Target']['Id'] for t in current_targets if t['Target']['Id'] != instance_id]
    
    if old_instances:
        elbv2.deregister_targets(TargetGroupArn=target_group_arn, Targets=[{'Id': i} for i in old_instances])
        ec2.terminate_instances(InstanceIds=old_instances)
    
    return {'instance_id': instance_id, 'terminated': old_instances}

if __name__ == '__main__':
    import sys
    result = lambda_handler({'instance_id': sys.argv[1]}, None)
    print(result)

if __name__ == '__main__':
    import sys
    result = lambda_handler({'instance_id': sys.argv[1]}, None)
    print(result)
