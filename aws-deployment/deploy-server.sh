#!/bin/bash

aws ec2 run-instances \
    --image-id ami-0c7217cdde317cfec \
    --instance-type t3.micro \
    --key-name gpxeditor_useast1 \
    --region us-east-1 \
    --user-data '#!/bin/bash
echo "Server initialized at $(date)" > /tmp/startup.log
'