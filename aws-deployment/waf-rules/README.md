# WAF Rule Definitions

This directory contains the JSON definitions for each WAF rule. These can be used as reference when manually creating rules in the AWS Console, or imported directly via the JSON editor.

## Rules

- **BlockIPSet.json** - Blocks IPs from the BlockedIPs IP set
- **BlockDirectIPAccess.json** - Blocks requests not using allowed hostnames
- **BlockScanners.json** - Blocks user-agents containing "scan"
- **BlockInvalidPaths.json** - Blocks paths that don't start with `/route`
- **BlockInvalidMethods.json** - Blocks HTTP methods other than GET and OPTIONS
- **RateLimit.json** - Rate limits to 2000 requests per 5 minutes per IP

## Usage

When creating rules in the AWS Console:

1. Click "Add rules" → "Add my own rules and rule groups"
2. Choose "Rule builder" or "JSON editor"
3. In JSON editor mode, you can paste the contents of these files directly
4. For visual editor mode, use these files as reference for the configuration

## Notes

- All SearchString values are plain text (no base64 encoding required in the UI)
- Text transformations use LOWERCASE for case-insensitive matching (except Method which uses NONE)
- Priority order: BlockIPSet (0) → BlockDirectIPAccess (1) → BlockScanners (2) → RateLimit (3) → BlockInvalidPaths (4) → BlockInvalidMethods (5) → RateLimit (6)
