#!/bin/bash
# Script to delete CloudWatch Log Groups across all AWS Org accounts
# Run in AWS CloudShell in the management (payer) account

# --- CONFIGURATION ---
ROLE_NAME="OrganizationAccountAccessRole"      # Cross-account role in each member account
MATCH_TEXT="Adaptive6InstallationLambda "          # Delete any log group whose name contains this text
SESSION_NAME="CloudShellCleanupSession"
REGION="us-east-1"              # Target region (single region only)

# Get list of all accounts in the Org
echo "Fetching AWS Organization accounts..."
ACCOUNT_IDS=$(aws organizations list-accounts \
    --query 'Accounts[?Status==`ACTIVE`].Id' \
    --output text)

if [ -z "$ACCOUNT_IDS" ]; then
    echo "No active accounts found in the Organization."
    exit 1
fi

for ACCOUNT_ID in $ACCOUNT_IDS; do
    echo "----"
    echo "Processing account: $ACCOUNT_ID"

    # Assume cross-account role
    CREDS=$(aws sts assume-role \
        --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
        --role-session-name "${SESSION_NAME}" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$CREDS" ]; then
        echo " Failed to assume role in account $ACCOUNT_ID"
        continue
    fi

    # Parse temporary credentials
    ACCESS_KEY=$(echo $CREDS | awk '{print $1}')
    SECRET_KEY=$(echo $CREDS | awk '{print $2}')
    SESSION_TOKEN=$(echo $CREDS | awk '{print $3}')

    # List log groups matching MATCH_TEXT
    LOG_GROUPS=$(AWS_ACCESS_KEY_ID=$ACCESS_KEY \
        AWS_SECRET_ACCESS_KEY=$SECRET_KEY \
        AWS_SESSION_TOKEN=$SESSION_TOKEN \
        aws logs describe-log-groups \
            --region "$REGION" \
            --query "logGroups[?contains(logGroupName, \`${MATCH_TEXT}\`)].logGroupName" \
            --output text 2>/dev/null)

    if [ -z "$LOG_GROUPS" ]; then
        echo "No matching log groups found in $ACCOUNT_ID ($REGION)"
        continue
    fi

    for LG in $LOG_GROUPS; do
        echo "Deleting log group: $LG"
        AWS_ACCESS_KEY_ID=$ACCESS_KEY \
        AWS_SECRET_ACCESS_KEY=$SECRET_KEY \
        AWS_SESSION_TOKEN=$SESSION_TOKEN \
        aws logs delete-log-group \
            --region "$REGION" \
            --log-group-name "$LG" \
            2>/dev/null

        if [ $? -eq 0 ]; then
            echo " Deleted $LG in account $ACCOUNT_ID"
        else
            echo " Could not delete $LG in account $ACCOUNT_ID"
        fi
    done
done

echo "----"
echo "Completed processing all accounts."