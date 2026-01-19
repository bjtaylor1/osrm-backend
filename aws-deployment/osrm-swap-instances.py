#!/usr/bin/env python3
import boto3

ec2 = boto3.client('ec2', region_name='us-east-1')
elbv2 = boto3.client('elbv2', region_name='us-east-1')

def get_target_group_arn(name='RouterTargetGroup'):
    """Get the ARN of a target group by name."""
    response = elbv2.describe_target_groups(Names=[name])
    target_groups = response.get('TargetGroups', [])
    
    if len(target_groups) == 0:
        raise ValueError(f"No target group found with name '{name}'")
    elif len(target_groups) > 1:
        raise ValueError(f"Multiple target groups found with name '{name}'")
    
    return target_groups[0]['TargetGroupArn']

TARGET_GROUP_ARN = get_target_group_arn()

def lambda_handler(event, context):
    instance_id = event['instance_id']
    
    # Configure waiter to wait up to 1 hour (240 attempts * 15 seconds = 3600 seconds)
    # For large datasets (e.g., planet-latest), the server can take up to 30-60 minutes to become healthy
    waiter = elbv2.get_waiter('target_in_service')
    waiter.config.delay = 15
    waiter.config.max_attempts = 240
    
    waiter.wait(TargetGroupArn=TARGET_GROUP_ARN, Targets=[{'Id': instance_id}])
    
    current_targets = elbv2.describe_target_health(TargetGroupArn=TARGET_GROUP_ARN)['TargetHealthDescriptions']
    old_instances = [t['Target']['Id'] for t in current_targets if t['Target']['Id'] != instance_id]
    
    if old_instances:
        elbv2.deregister_targets(TargetGroupArn=TARGET_GROUP_ARN, Targets=[{'Id': i} for i in old_instances])
        ec2.terminate_instances(InstanceIds=old_instances)
    
    return {'instance_id': instance_id, 'terminated': old_instances}

if __name__ == '__main__':
    import sys
    result = lambda_handler({'instance_id': sys.argv[1]}, None)
    print(result)
