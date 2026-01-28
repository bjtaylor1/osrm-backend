AWS_PROFILE=gpxeditorroot


folder=s3://my-osrm-access-logs/router/AWSLogs/259514351789/elasticloadbalancing/us-east-1/2026/01/28

logfile=~/Downloads/elb.log
rm -f $logfile

for f in $(aws s3 ls "$folder/" | awk '{print $4}'); do
  #echo $f
  
  aws s3 cp "$folder/$f" - | gunzip >> $logfile
  aws s3 rm "$folder/$f"
done
