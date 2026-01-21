#!/usr/bin/env python3
import boto3
from osrm_utils import get_target_group_arn

elbv2 = boto3.client('elbv2', region_name='us-east-1')


def lambda_handler(event, context):
    instance_id = event['instance_id']
    target_group_name = event['target_group_name']
    
    # Look up the target group ARN from its name
    target_group_arn = get_target_group_arn(target_group_name)
    
    # Check if the target is healthy
    response = elbv2.describe_target_health(
        TargetGroupArn=target_group_arn,
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
