# AWS WAF Manual Setup Guide

This guide walks you through setting up AWS WAF for the RouterLoadBalancer via the AWS Console.

## Prerequisites

- AWS Console access to the `gpxeditorroot` account
- RouterLoadBalancer already deployed in us-east-1

## Step 1: Create IP Set

1. Navigate to [AWS WAF Console](https://console.aws.amazon.com/wafv2/homev2)
2. Ensure you're in **US East (N. Virginia)** region
3. Click **IP sets** in the left sidebar
4. Click **Create IP set**
5. Configure:
   - **IP set name**: `BlockedIPs`
   - **Region**: Regional
   - **IP version**: IPv4
   - **IP addresses**: Leave empty for now (will be managed by script)
6. Click **Create IP set**

## Step 2: Create Web ACL

1. In WAF Console, click **Web ACLs** in the left sidebar
2. Click **Create web ACL**

### Basic configuration

- **Name**: `RouterLoadBalancerWAF`
- **Resource type**: Regional resources (Application Load Balancer, API Gateway, etc.)
- **Region**: US East (N. Virginia)
- Click **Next**

### Associated AWS resources

- Click **Add AWS resources**
- Select **Application Load Balancer**
- Check the box next to **RouterLoadBalancer**
- Click **Add**
- Click **Next**

### Add rules and rule groups

Add the following 4 rules in order. You can use the JSON editor or rule builder.

**Reference files**: See `waf-rules/` folder for complete JSON definitions of each rule.

#### Rule 1: BlockIPSet

**Using JSON Editor:**
- Click **Add rules** → **Add my own rules and rule groups** → **Rule builder** → Switch to **JSON editor**
- Copy contents from `waf-rules/BlockIPSet.json`
- Replace `YOUR_IP_SET_ARN_HERE` with your actual IP set ARN
- Click **Add rule**

**Using Rule Builder:**
- Click **Add rules** → **Add my own rules and rule groups** → **IP set**
- **Name**: `BlockIPSet`
- **IP set**: Select `BlockedIPs`
- **IP address to use**: Source IP address
- **Action**: Block
- Click **Add rule**

#### Rule 2: BlockDirectIPAccess

**Using JSON Editor:**
- Copy contents from `waf-rules/BlockDirectIPAccess.json`
- Click **Add rule**

**Using Rule Builder:**
- **Name**: `BlockDirectIPAccess`
- **Type**: Regular rule
- **If a request**: doesn't match the statement (NOT)
- **Inspect**: Header - `host` (lowercase)
- **Match type**: Matches string exactly
- **String to match**: `router3.gpxplanner.app`
- **Text transformation**: Lowercase

Click **Add new condition (OR)** and repeat for:
- `gpxplanner.app`
- `www.gpxeditor.co.uk`
- `gpxeditor.co.uk`

- **Action**: Block
- Click **Add rule**

#### Rule 3: BlockScanners

**Using JSON Editor:**
- Copy contents from `waf-rules/BlockScanners.json`
- Click **Add rule**

**Using Rule Builder:**
- **Name**: `BlockScanners`
- **Type**: Regular rule
- **If a request**: matches the statement
- **Inspect**: Header - `user-agent` (lowercase)
- **Match type**: Contains string
- **String to match**: `scan`
- **Text transformation**: Lowercase
- **Action**: Block
**Using JSON Editor:**
- Copy contents from `waf-rules/RateLimit.json`
- Click **Add rule**

**Using Rule Builder:

#### Rule 4: RateLimit

- Click **Add rules** → **Add my own rules and rule groups** → **Rule builder**
- **Name**: `RateLimit`
- **Type**: Rate-based rule
- **Rate limit**: `2000`
- **IP address to use**: Source IP address
- **Action**: Block
- Click **Add rule**

Click **Next**

### Set rule priority

Ensure rules are in this order (drag to reorder if needed):
1. BlockIPSet (Priority 0)
2. BlockDirectIPAccess (Priority 1)
3. BlockScanners (Priority 2)
4. RateLimit (Priority 3)

Click **Next**

### Configure metrics

- Leave CloudWatch metrics enabled
- Click **Next**

### Review and create

- Review all settings
- Click **Create web ACL**

## Step 3: Verify Setup

1. Go to **Web ACLs** → Click **RouterLoadBalancerWAF**
2. Check **Rules** tab: Should show 4 rules
3. Check **Associated AWS resources** tab: Should show RouterLoadBalancer
4. Go to **IP sets** → Click **BlockedIPs**: Should be ready to receive IPs

## Managing the Blocklist

After manual setup, use the script to update blocked IPs:

```bash
# Edit ip-blocklist.txt to add/remove IPs
# Then run:
AWS_PROFILE=gpxeditorroot ./waf-update-blocklist.sh
```

The script will automatically update the IP set with your changes.

## Notes

- The IP set can hold up to 10,000 IPs using just ONE rule
- Rate limit is 2000 requests per 5-minute window per IP
- All rules use CloudWatch metrics for monitoring
- Changes to the IP set take effect immediately
