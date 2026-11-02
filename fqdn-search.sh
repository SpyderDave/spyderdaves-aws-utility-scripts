#!/bin/bash

# Target FQDN to find (Note: Route 53 appends a trailing dot to names, e.g., "app.example.com.")
TARGET_FQDN="app.example.com."
ROLE_NAME="OrganizationAccountAccessRole" # Change to your cross-account role name

echo "Searching for FQDN: $TARGET_FQDN..."

# 1. Get all active accounts in the Organization
ACCOUNTS=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text)

for ACCOUNT_ID in $ACCOUNTS; do
    echo "Scanning Account: $ACCOUNT_ID..."
    
    # 2. Assume role into the target child account
    CREDENTIALS=$(aws sts assume-role \
        --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
        --role-session-name "Route53Search" \
        --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
        --output text 2>/dev/null)
    
    if [ -z "$CREDENTIALS" ]; then
        echo "   [!] Could not assume role for account $ACCOUNT_ID. Skipping."
        continue
    fi
    
    # Extract temporary credentials
    export AWS_ACCESS_KEY_ID=$(echo "$CREDENTIALS" | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo "$CREDENTIALS" | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo "$CREDENTIALS" | awk '{print $3}')
    
    # 3. List all hosted zones in this specific account
    ZONES=$(aws route53 list-hosted-zones --query "HostedZones[*].Id" --output text 2>/dev/null)
    
    for ZONE_ID in $ZONES; do
        # 4. Check if the FQDN exists in this zone
        # Route 53 filters by name natively but may return partial matches; JMESPath query ensures exact match
        RECORD=$(aws route53 list-resource-record-sets \
            --hosted-zone-id "$ZONE_ID" \
            --query "ResourceRecordSets[?Name=='${TARGET_FQDN}']" \
            --output json 2>/dev/null)
        
        if [ "$RECORD" != "[]" ] && [ ! -z "$RECORD" ]; then
            echo "   [+] FOUND in Account: $ACCOUNT_ID | Hosted Zone: $ZONE_ID"
            echo "$RECORD"
        fi
    done
    
    # Clean up credentials before moving to the next account
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done
