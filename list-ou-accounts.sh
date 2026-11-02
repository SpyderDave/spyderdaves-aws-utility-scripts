#!/bin/bash

#############################################################################
# Script: list-ou-accounts.sh
# Description: Lists all AWS Organization member accounts within a specific OU
#              including accounts in any nested OUs
# Usage: ./list-ou-accounts.sh <OU-ID>
# Example: ./list-ou-accounts.sh ou-abcd-12345678
#############################################################################

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Validate input
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <OU-ID>"
    echo "Example: $0 ou-abcd-12345678"
    exit 1
fi

OU_ID="$1"

# Validate OU ID format
if [[ ! $OU_ID =~ ^ou-[a-z0-9]{4}-[a-z0-9]{8}$ ]]; then
    echo -e "${YELLOW}Warning: OU-ID format may be incorrect. Expected format: ou-xxxx-xxxxxxxx${NC}"
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

# Temporary file to store all accounts
TEMP_ACCOUNTS=$(mktemp)
trap "rm -f $TEMP_ACCOUNTS" EXIT

#############################################################################
# Function to recursively list all accounts in an OU and its children
#############################################################################
list_accounts_recursive() {
    local ou_id="$1"
    local indent="$2"

    # Get direct accounts in this OU
    echo -e "${indent}${BLUE}Processing OU: $ou_id${NC}" >&2

    local accounts
    accounts=$(aws organizations list-accounts-for-parent \
        --parent-id "$ou_id" \
        --query 'Accounts[].{Id:Id,Name:Name,Status:Status,Email:Email}' \
        --output json 2>/dev/null || echo "[]")

    # Parse and store accounts
    echo "$accounts" | jq -r '.[] | "\(.Id)|\(.Name)|\(.Status)|\(.Email)|'"$ou_id"'"' >> "$TEMP_ACCOUNTS"

    # Get child OUs
    local children
    children=$(aws organizations list-children \
        --parent-id "$ou_id" \
        --child-type ORGANIZATIONAL_UNIT \
        --query 'Children[].Id' \
        --output text 2>/dev/null || echo "")

    # Recursively process child OUs
    for child_ou in $children; do
        list_accounts_recursive "$child_ou" "${indent}  "
    done
}

#############################################################################
# Main execution
#############################################################################

echo -e "${GREEN}Listing all accounts in OU: $OU_ID${NC}"
echo "This may take a moment for large OUs with nested structures..."
echo ""

# Get OU name for display
OU_NAME=$(aws organizations describe-organizational-unit \
    --organizational-unit-id "$OU_ID" \
    --query 'OrganizationalUnit.Name' \
    --output text 2>/dev/null || echo "Unknown")

echo -e "${GREEN}OU Name: $OU_NAME${NC}"
echo ""

# Start recursive listing
list_accounts_recursive "$OU_ID" ""

# Output CSV format
if [[ -s $TEMP_ACCOUNTS ]]; then
    # Print CSV header
    echo "AccountId,AccountName,Status,Email,ParentOu"

    # Sort by parent OU then account ID and output as CSV
    sort -t'|' -k5,5 -k1,1 "$TEMP_ACCOUNTS" | while IFS='|' read -r id name status email parent_ou; do
        # Escape quotes in field values and wrap fields with quotes for CSV compliance
        id=$(echo "$id" | sed 's/"/""/g')
        name=$(echo "$name" | sed 's/"/""/g')
        status=$(echo "$status" | sed 's/"/""/g')
        email=$(echo "$email" | sed 's/"/""/g')
        parent_ou=$(echo "$parent_ou" | sed 's/"/""/g')

        echo "\"$id\",\"$name\",\"$status\",\"$email\",\"$parent_ou\""
    done

    echo "" >&2
    echo -e "${GREEN}Total accounts found: $(wc -l < "$TEMP_ACCOUNTS")${NC}" >&2
else
    echo -e "${YELLOW}No accounts found in the specified OU.${NC}" >&2
    exit 1
fi
