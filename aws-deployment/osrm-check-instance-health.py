#!/usr/bin/env python3
import boto3

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
    
    # Check if the target is healthy
    response = elbv2.describe_target_health(
        TargetGroupArn=TARGET_GROUP_ARN,
        Targets=[{'Id': instance_id}]
    )
    
    if not response['TargetHealthDescriptions']:
        return {'status': 'not_registered', 'instance_id': instance_id}
    
    health_state = response['TargetHealthDescriptions'][0]['TargetHealth']['State']
    return {'status': health_state, 'instance_id': instance_id}

if __name__ == '__main__':
    import sys
    result = lambda_handler({'instance_id': sys.argv[1]}, None)
    print(result)
