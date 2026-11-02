#!/bin/bash

OUTPUT="iam_console_user_security_report.csv"
ROLE_NAME="OrganizationAccountAccessRole"

# Save original credentials (management account)
ORIG_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
ORIG_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
ORIG_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

echo "AccountId,AccountName,AccountOwner,UserName,ConsoleAccess,MFAEnabled,AccessKeyCount,PasswordLastUsed,CreateDate" > $OUTPUT

echo "Retrieving AWS Organization accounts..."

aws organizations list-accounts \
  --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' \
  --output text | while read account_id account_name
do

  # Restore management account credentials before org calls
  export AWS_ACCESS_KEY_ID=$ORIG_AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$ORIG_AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN=$ORIG_AWS_SESSION_TOKEN

  echo "Processing account: $account_name ($account_id)"

  # Get AccountOwner tag
  account_owner=$(aws organizations list-tags-for-resource \
    --resource-id "$account_id" \
    --query 'Tags[?Key==`AccountOwner`].Value' \
    --output text)

  if [ -z "$account_owner" ]; then
      account_owner="UNKNOWN"
  fi

  # Assume role in the member account
  creds=$(aws sts assume-role \
    --role-arn arn:aws:iam::$account_id:role/$ROLE_NAME \
    --role-session-name IAMSecurityAudit \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>/dev/null)

  if [ $? -ne 0 ]; then
      echo "Failed to assume role in $account_id"
      continue
  fi

  export AWS_ACCESS_KEY_ID=$(echo $creds | awk '{print $1}')
  export AWS_SECRET_ACCESS_KEY=$(echo $creds | awk '{print $2}')
  export AWS_SESSION_TOKEN=$(echo $creds | awk '{print $3}')

  users=$(aws iam list-users \
      --query 'Users[*].[UserName,PasswordLastUsed,CreateDate]' \
      --output text)

  while read username pwdlastused created
  do

      console_access="false"

      aws iam get-login-profile --user-name "$username" >/dev/null 2>&1
      if [ $? -eq 0 ]; then
          console_access="true"
      fi

      if [ "$console_access" != "true" ]; then
          continue
      fi

      # MFA status
      mfa_devices=$(aws iam list-mfa-devices \
          --user-name "$username" \
          --query 'MFADevices' \
          --output json)

      if [ "$mfa_devices" == "[]" ]; then
          mfa_enabled="false"
      else
          mfa_enabled="true"
      fi

      # Access key count
      access_keys=$(aws iam list-access-keys \
          --user-name "$username" \
          --query 'AccessKeyMetadata[*].AccessKeyId' \
          --output text)

      if [ -z "$access_keys" ]; then
          key_count=0
      else
          key_count=$(echo "$access_keys" | wc -w)
      fi

      echo "$account_id,\"$account_name\",\"$account_owner\",$username,$console_access,$mfa_enabled,$key_count,$pwdlastused,$created" >> $OUTPUT

  done <<< "$users"

done

# Restore original credentials
export AWS_ACCESS_KEY_ID=$ORIG_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$ORIG_AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN=$ORIG_AWS_SESSION_TOKEN

echo "Audit complete. Output saved to $OUTPUT"

