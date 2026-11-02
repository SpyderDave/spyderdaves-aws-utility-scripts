#!/bin/bash
# Deletes a specifically named CloudWatch Log Group, in every enabled region
# of the current account, if it exists there.

set -euo pipefail

LOG_GROUP_NAME="${1:-}"

if [[ -z "$LOG_GROUP_NAME" ]]; then
  echo "Usage: $0 <log-group-name>"
  exit 1
fi

# Get all enabled AWS regions, excluding me-central-1 and me-south-1
regions=$(aws ec2 describe-regions --query "Regions[?RegionName!='me-central-1' && RegionName!='me-south-1'].RegionName" --output text)

for region in $regions; do
  echo "Checking region: $region"

  exists=$(aws logs describe-log-groups \
    --region "$region" \
    --log-group-name-prefix "$LOG_GROUP_NAME" \
    --query "logGroups[?logGroupName=='${LOG_GROUP_NAME}'].logGroupName" \
    --output text 2>/dev/null || true)

  if [[ -n "$exists" ]]; then
    echo "Deleting log group: $LOG_GROUP_NAME in $region"
    aws logs delete-log-group \
      --region "$region" \
      --log-group-name "$LOG_GROUP_NAME"
  else
    echo "Not found in $region"
  fi
done

echo "Completed log group cleanup across all regions."
