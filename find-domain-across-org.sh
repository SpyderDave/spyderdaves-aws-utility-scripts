#!/bin/bash

TARGET_DOMAIN="lifeworks.com"
ROLE_NAME="OrganizationAccountAccessRole"
REGION="us-east-1"

echo "Searching for hosted zone: $TARGET_DOMAIN"
echo "----------------------------------------"

# Get list of ACTIVE accounts in the Org
ACCOUNTS=$(aws organizations list-accounts \
  --query "Accounts[?Status=='ACTIVE'].Id" \
  --output text)

for ACCOUNT in $ACCOUNTS; do
  echo "Checking account: $ACCOUNT"

  # Assume role into member account
  CREDS=$(aws sts assume-role \
    --role-arn arn:aws:iam::$ACCOUNT:role/$ROLE_NAME \
    --role-session-name Route53SearchSession \
    --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
    --output text 2>/dev/null)

  if [ -z "$CREDS" ]; then
    echo "  Could not assume role"
    continue
  fi

  read AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< $CREDS

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN

  # Search hosted zones
  ZONES=$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='$TARGET_DOMAIN.'].Id" \
    --output text 2>/dev/null)

  if [ ! -z "$ZONES" ]; then
    echo "  FOUND in account $ACCOUNT"
    echo "     Hosted Zone ID: $ZONES"
  else
    echo "  Not found"
  fi

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done

echo "-----------------------