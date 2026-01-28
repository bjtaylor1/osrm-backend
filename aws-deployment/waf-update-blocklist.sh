#!/bin/bash
#
# Update AWS WAF IP blocklist
#
# This script updates the BlockedIPs IP set in an existing WAF configuration.
# Run the manual setup first (see WAF_SETUP_GUIDE.md)
#
# Usage: ./waf-update-blocklist.sh [blocklist-file]
#
# Blocklist format (everything after # is ignored):
#   192.168.1.100 # Malicious scanner
#   10.0.0.50/24 # DDoS source network
#   # Lines starting with # are skipped
#

set -e

BLOCKLIST_FILE="${1:-waf-ip-blocklist.txt}"
IP_SET_NAME="BlockedIPs"

if [[ ! -f "$BLOCKLIST_FILE" ]]; then
    echo "Error: Blocklist file '$BLOCKLIST_FILE' not found"
    exit 1
fi

echo "Updating WAF IP blocklist"
echo "========================="
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

echo "Reading blocklist from: $BLOCKLIST_FILE"
echo "Found ${#BLOCKED_IPS[@]} IP(s) to block"
read -p "Press Enter to confirm and proceed with updating the WAF IP set..." confirmation
echo

# Get IP Set details
echo "Looking up IP set: $IP_SET_NAME"
IP_SET_INFO=$(aws wafv2 list-ip-sets --scope REGIONAL --query "IPSets[?Name=='$IP_SET_NAME'] | [0]" --output json)

if [[ -z "$IP_SET_INFO" || "$IP_SET_INFO" == "null" ]]; then
    echo "Error: IP set '$IP_SET_NAME' not found"
    echo
    echo "It looks like the WAF has not been set up yet."
    echo "Please follow the manual setup guide in WAF_SETUP_GUIDE.md first."
    exit 1
fi

IP_SET_ID=$(echo "$IP_SET_INFO" | jq -r '.Id')
IP_SET_ARN=$(echo "$IP_SET_INFO" | jq -r '.ARN')
echo "✓ Found IP set: $IP_SET_ID"
echo

# Get current lock token
echo "Retrieving IP set lock token..."
LOCK_TOKEN=$(aws wafv2 get-ip-set --scope REGIONAL --id "$IP_SET_ID" --name "$IP_SET_NAME" --query 'LockToken' --output text)
echo "✓ Lock token acquired"
echo

# Update IP set
echo "Updating IP set with new blocklist..."
if aws wafv2 update-ip-set \
    --scope REGIONAL \
    --id "$IP_SET_ID" \
    --name "$IP_SET_NAME" \
    --addresses "${BLOCKED_IPS[@]}" \
    --lock-token "$LOCK_TOKEN" 2>&1; then
    echo
    echo "✓ Successfully updated WAF IP set with ${#BLOCKED_IPS[@]} IP(s)"
    echo
    echo "The changes are effective immediately."
    echo "All ${#BLOCKED_IPS[@]} IPs are blocked by the BlockIPSet rule."
else
    echo
    echo "Error: Failed to update IP set"
    exit 1
fi
