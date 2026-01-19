#!/usr/bin/env python3
import boto3

ec2 = boto3.client('ec2', region_name='us-east-1')  # For waiter only
elbv2 = boto3.client('elbv2', region_name='us-east-1')

TARGET_GROUP_ARN = 'arn:aws:elasticloadbalancing:us-east-1:259514351789:targetgroup/RouterTargetGroup/3e36e81cc0d20dfe'

def lambda_handler(event, context):
    instance_id = event['instance_id']
    ec2.get_waiter('instance_running').wait(InstanceIds=[instance_id])
    
    # Register instance with target group
    # No need to modify security group - instance was created with 'allow-http-from-load-balancer' security group
    elbv2.register_targets(TargetGroupArn=TARGET_GROUP_ARN, Targets=[{'Id': instance_id}])
    return {'instance_id': instance_id}

if __name__ == '__main__':
    import sys
    result = lambda_handler({'instance_id': sys.argv[1]}, None)
    print(result)
