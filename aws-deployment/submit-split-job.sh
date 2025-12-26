SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

(cd $SCRIPT_DIR && aws batch submit-job --cli-input-json file://splitjob.json --region us-east-1 )
