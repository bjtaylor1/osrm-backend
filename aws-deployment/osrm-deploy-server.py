#!/usr/bin/env python3
import boto3
import os
from datetime import datetime
from osrm_utils import get_router_ami, get_security_group

ec2 = boto3.client('ec2', region_name='us-east-1')


def lambda_handler(event, context):
    router_region = event['router_region']
    
    if router_region == 'planet-latest':
        instance_type = 'i3.large'
        swap_space = '102400'
    else:
        instance_type = 't3.micro'
        swap_space = '1024'
    
    instance_name = f"Router{datetime.now().strftime('%Y%m%d')}"
    
    # Get the RouterImage AMI dynamically
    router_ami_id = get_router_ami()
    
    # Get the security group for allowing HTTP from load balancer
    security_group_id = get_security_group()
    
    with open(os.path.join(os.path.dirname(__file__), 'deploy-server.startup-script.sh')) as f:
        user_data = f.read()
    
    response = ec2.run_instances(
        ImageId=router_ami_id,
        InstanceType=instance_type,
        SecurityGroupIds=[security_group_id],
        IamInstanceProfile={'Name': 'OSRM-Instance-Profile'},
        KeyName='gpxeditor_useast1',
        MinCount=1,
        MaxCount=1,
        TagSpecifications=[{
            'ResourceType': 'instance',
            'Tags': [
                {'Key': 'Name', 'Value': instance_name},
                {'Key': 'router-region', 'Value': router_region},
                {'Key': 'swap-space', 'Value': swap_space}
            ]
        }],
        UserData=user_data
    )
    
    instance_id = response['Instances'][0]['InstanceId']
    return {'instance_id': instance_id, 'router_region': router_region}

if __name__ == '__main__':
    import sys
    result = lambda_handler({'router_region': sys.argv[1] if len(sys.argv) > 1 else 'planet-latest'}, None)
    print(result)
