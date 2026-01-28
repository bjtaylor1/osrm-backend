#!/bin/bash
#
# Setup AWS WAF for RouterLoadBalancer
#
# This script creates:
# - Web ACL with smart blocking rules
# - IP set for blocklist management
# - Rules to block scanners and direct IP access
#
# Usage: ./waf-setup.sh [blocklist-file]
#

set -e

BLOCKLIST_FILE="${1:-ip-blocklist.txt}"
LB_NAME="RouterLoadBalancer"
WAF_NAME="RouterLoadBalancerWAF"
IP_SET_NAME="BlockedIPs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="$SCRIPT_DIR/waf-rules.json"

echo "Setting up WAF for load balancer: $LB_NAME"
echo

# Get load balancer ARN
echo "Looking up load balancer..."
LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
if [[ -z "$LB_ARN" || "$LB_ARN" == "None" ]]; then
    echo "Error: Load balancer '$LB_NAME' not found"
    exit 1
fi
echo "✓ Found load balancer: $LB_ARN"
echo

# Parse blocklist if provided
BLOCKED_IPS=()
if [[ -f "$BLOCKLIST_FILE" ]]; then
    echo "Reading blocklist from: $BLOCKLIST_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and lines starting with #
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Extract CIDR (everything before #)
        cidr=$(echo "$line" | cut -d'#' -f1 | tr -d ' ')
        # Add /32 if no CIDR suffix present
        [[ -n "$cidr" && ! "$cidr" =~ / ]] && cidr="${cidr}/32"
        [[ -n "$cidr" ]] && BLOCKED_IPS+=("$cidr")
    done < "$BLOCKLIST_FILE"
    echo "✓ Found ${#BLOCKED_IPS[@]} IP(s) to block"
    echo
fi

# Create IP Set
echo "Creating IP set: $IP_SET_NAME"
IP_SET_ARN=$(aws wafv2 create-ip-set \
    --name "$IP_SET_NAME" \
    --scope REGIONAL \
    --ip-address-version IPV4 \
    --addresses "${BLOCKED_IPS[@]:-}" \
    --query 'Summary.ARN' \
    --output text 2>/dev/null || \
    aws wafv2 list-ip-sets --scope REGIONAL --query "IPSets[?Name=='$IP_SET_NAME'].ARN | [0]" --output text)

if [[ -z "$IP_SET_ARN" || "$IP_SET_ARN" == "None" ]]; then
    echo "Error: Failed to create or find IP set"
    exit 1
fi
echo "✓ IP Set ARN: $IP_SET_ARN"
echo

# Load and prepare WAF rules from JSON file
echo "Loading WAF rules from: $RULES_FILE"
if [[ ! -f "$RULES_FILE" ]]; then
    echo "Error: WAF rules file not found: $RULES_FILE"
    exit 1
fi

# Replace IP_SET_ARN_PLACEHOLDER with actual ARN
WAF_CONFIG=$(cat "$RULES_FILE" | sed "s|IP_SET_ARN_PLACEHOLDER|$IP_SET_ARN|g")
echo "$WAF_CONFIG" > /tmp/waf-rules.json
echo "✓ WAF rules prepared"
echo

# Create or update Web ACL
echo "Creating Web ACL: $WAF_NAME"
WEB_ACL_ARN=$(aws wafv2 create-web-acl \
    --cli-input-json file:///tmp/waf-rules.json \
    --query 'Summary.ARN' \
    --output text 2>/dev/null || \
    aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name=='$WAF_NAME'].ARN | [0]" --output text)

if [[ -z "$WEB_ACL_ARN" || "$WEB_ACL_ARN" == "None" ]]; then
    echo "Error: Failed to create Web ACL"
    rm /tmp/waf-rules.json
    exit 1
fi
echo "✓ Web ACL ARN: $WEB_ACL_ARN"
rm /tmp/waf-rules.json
echo

# Associate Web ACL with Load Balancer
echo "Associating Web ACL with load balancer..."
aws wafv2 associate-web-acl \
    --web-acl-arn "$WEB_ACL_ARN" \
    --resource-arn "$LB_ARN"
echo "✓ Web ACL associated with load balancer"
echo

echo "=================================================="
echo "✓ WAF Setup Complete!"
echo "=================================================="
echo
echo "Web ACL: $WAF_NAME"
echo "IP Set: $IP_SET_NAME (${#BLOCKED_IPS[@]} IPs)"
echo
echo "Active Rules:"
echo "  0. BlockIPSet - Blocks IPs from blocklist (ONE rule for ALL IPs)"
echo "  1. BlockDirectIPAccess - Blocks requests not using allowed hostnames"
echo "  2. BlockScanners - Blocks user-agents containing 'scan'"
echo "  3. RateLimit - Blocks IPs exceeding 2000 requests per 5 minutes"
echo
echo "Allowed Hostnames:"
echo "  - router3.gpxplanner.app"
echo "  - gpxplanner.app"
echo "  - www.gpxeditor.co.uk"
echo "  - gpxeditor.co.uk"
echo
echo "To update the IP blocklist, use: ./waf-update-blocklist.sh"
echo
echo "Note: The IP Set can hold up to 10,000 IPs using just ONE WAF rule!"
