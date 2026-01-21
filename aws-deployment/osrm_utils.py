#!/usr/bin/env python3
"""
Shared utilities for OSRM Lambda functions.
This module provides common functionality for interacting with AWS services.
"""

import boto3


def get_target_group_arn(target_group_name, region_name='us-east-1'):
    """
    Get the ARN of a target group by name.
    
    Args:
        target_group_name: Name of the target group to look up
        region_name: AWS region (defaults to us-east-1)
    
    Returns:
        str: ARN of the target group
        
    Raises:
        ValueError: If the target group doesn't exist or multiple target groups with the same name exist
    """
    elbv2 = boto3.client('elbv2', region_name=region_name)
    
    try:
        response = elbv2.describe_target_groups(Names=[target_group_name])
    except elbv2.exceptions.TargetGroupNotFoundException:
        raise ValueError(f"Target group '{target_group_name}' not found")
    
    target_groups = response.get('TargetGroups', [])
    
    if len(target_groups) == 0:
        raise ValueError(f"No target group found with name '{target_group_name}'")
    elif len(target_groups) > 1:
        raise ValueError(f"Multiple target groups found with name '{target_group_name}'. Expected exactly one.")
    
    return target_groups[0]['TargetGroupArn']


def get_router_ami(region_name='us-east-1'):
    """
    Get the RouterImage AMI owned by the current AWS account.
    
    Args:
        region_name: AWS region (defaults to us-east-1)
    
    Returns:
        str: AMI ID of the RouterImage
        
    Raises:
        ValueError: If the AMI doesn't exist or if there's more than one
    """
    ec2 = boto3.client('ec2', region_name=region_name)
    sts = boto3.client('sts')
    
    # Get the current account ID
    account_id = sts.get_caller_identity()['Account']
    
    # Search for AMIs named "RouterImage" owned by this account
    response = ec2.describe_images(
        Owners=[account_id],
        Filters=[
            {'Name': 'name', 'Values': ['RouterImage']}
        ]
    )
    
    images = response['Images']
    
    if len(images) == 0:
        raise ValueError(f"No AMI named 'RouterImage' found owned by account {account_id}")
    elif len(images) > 1:
        raise ValueError(f"Multiple AMIs named 'RouterImage' found ({len(images)} images). Please ensure only one exists.")
    
    return images[0]['ImageId']


def get_security_group(security_group_name='allow-http-from-load-balancer', region_name='us-east-1'):
    """
    Get a security group by name.
    
    Args:
        security_group_name: Name of the security group (defaults to 'allow-http-from-load-balancer')
        region_name: AWS region (defaults to us-east-1)
    
    Returns:
        str: Security group ID
        
    Raises:
        ValueError: If the security group doesn't exist or if there's more than one
    """
    ec2 = boto3.client('ec2', region_name=region_name)
    
    response = ec2.describe_security_groups(
        Filters=[
            {'Name': 'group-name', 'Values': [security_group_name]}
        ]
    )
    
    security_groups = response['SecurityGroups']
    
    if len(security_groups) == 0:
        raise ValueError(f"No security group named '{security_group_name}' found")
    elif len(security_groups) > 1:
        raise ValueError(f"Multiple security groups named '{security_group_name}' found ({len(security_groups)} groups). Please ensure only one exists.")
    
    return security_groups[0]['GroupId']
