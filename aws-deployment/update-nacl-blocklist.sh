#!/bin/bash
#
# Update AWS Network ACL with IP blocklist
# 
# Usage: ./update-nacl-blocklist.sh <blocklist-file> [nacl-id]
#
# Blocklist format (everything after # is ignored):
#   192.168.1.100/32 # Malicious scanner
#   10.0.0.50/32 # DDoS source
#   # Lines starting with # are skipped
#

set -e

BLOCKLIST_FILE="${1:-ip-blocklist.txt}"
LB_NAME="RouterLoadBalancer"

if [[ ! -f "$BLOCKLIST_FILE" ]]; then
    echo "Error: Blocklist file '$BLOCKLIST_FILE' not found"
    exit 1
fi

echo "Looking up NACL for load balancer: $LB_NAME"

# Get load balancer details
LB_INFO=$(aws elbv2 describe-load-balancers --names "$LB_NAME" 2>/dev/null)
if [[ -z "$LB_INFO" ]]; then
    echo "Error: Load balancer '$LB_NAME' not found"
    exit 1
fi

# Extract subnet IDs from the load balancer
SUBNET_IDS=$(echo "$LB_INFO" | jq -r '.LoadBalancers[0].AvailabilityZones[].SubnetId' | head -n 1)
if [[ -z "$SUBNET_IDS" ]]; then
    echo "Error: No subnets found for load balancer '$LB_NAME'"
    exit 1
fi

# Get the NACL associated with the first subnet
NACL_ID=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SUBNET_IDS" --query 'NetworkAcls[0].NetworkAclId' --output text)
if [[ -z "$NACL_ID" || "$NACL_ID" == "None" ]]; then
    echo "Error: Could not find NACL associated with load balancer '$LB_NAME'"
    exit 1
fi

echo "✓ Found NACL: $NACL_ID"
echo "Reading blocklist from: $BLOCKLIST_FILE"
echo

# Parse blocklist - extract IPs (everything before #), skip comment lines
BLOCKED_IPS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and lines starting with #
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Extract CIDR (everything before #)
    cidr=$(echo "$line" | cut -d'#' -f1 | tr -d ' ')
    # Add /32 if no CIDR suffix present
    [[ -n "$cidr" && ! "$cidr" =~ / ]] && cidr="${cidr}/32"
    [[ -n "$cidr" ]] && BLOCKED_IPS+=("$cidr")
done < "$BLOCKLIST_FILE"

if [[ ${#BLOCKED_IPS[@]} -eq 0 ]]; then
    echo "Error: No valid IP addresses found in blocklist"
    exit 1
fi

echo "Found ${#BLOCKED_IPS[@]} IP(s) to block:"
printf '  %s\n' "${BLOCKED_IPS[@]}"
echo
read -p "Press Enter to confirm and proceed with updating the NACL..." confirmation
echo

# Delete all existing non-default ingress rules
echo "Deleting existing ingress rules..."
aws ec2 describe-network-acls --network-acl-ids "$NACL_ID" --query 'NetworkAcls[0].Entries[?Egress==`false` && RuleNumber<`32767`].RuleNumber' --output text | \
    tr '\t' '\n' | while read -r rule_num; do
        [[ -n "$rule_num" ]] && aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number "$rule_num" --ingress
        echo "  Deleted rule $rule_num"
    done

# Add deny rules for blocked IPs (ingress only)
echo
echo "Adding deny rules..."
rule_num=100
for cidr in "${BLOCKED_IPS[@]}"; do
    aws ec2 create-network-acl-entry \
        --network-acl-id "$NACL_ID" \
        --rule-number "$rule_num" \
        --protocol -1 \
        --rule-action deny \
        --ingress \
        --cidr-block "$cidr"
    echo "  Rule $rule_num: DENY $cidr"
    ((rule_num++))
done

# Add allow-all rule
echo
echo "Adding allow-all rule..."
aws ec2 create-network-acl-entry \
    --network-acl-id "$NACL_ID" \
    --rule-number "$rule_num" \
    --protocol -1 \
    --rule-action allow \
    --ingress \
    --cidr-block 0.0.0.0/0
echo "  Rule $rule_num: ALLOW 0.0.0.0/0"

echo
echo "✓ Successfully updated NACL $NACL_ID"
