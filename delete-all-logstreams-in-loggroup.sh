#!/usr/bin/env bash

set -euo pipefail

LOG_GROUP_NAME="$1"

if [[ -z "$LOG_GROUP_NAME" ]]; then
  echo "Usage: $0 <log-group-name> [region]"
  exit 1
fi

REGION="${2:-}"

# Optional region flag
REGION_FLAG=""
if [[ -n "$REGION" ]]; then
  REGION_FLAG="--region $REGION"
fi

echo "Deleting all log streams in log group: $LOG_GROUP_NAME"
echo

# Paginate through all log streams
next_token=""

while true; do
  if [[ -n "$next_token" ]]; then
    output=$(aws logs describe-log-streams \
      --log-group-name "$LOG_GROUP_NAME" \
      --max-items 50 \
      --starting-token "$next_token" \
      $REGION_FLAG)
  else
    output=$(aws logs describe-log-streams \
      --log-group-name "$LOG_GROUP_NAME" \
      --max-items 50 \
      $REGION_FLAG)
  fi

  # Extract names
  stream_names=$(echo "$output" | jq -r '.logStreams[].logStreamName')

  if [[ -z "$stream_names" ]]; then
    echo "No more log streams found."
    break
  fi

  # Delete each log stream
  for s in $stream_names; do
    echo "Deleting log stream: $s"
    aws logs delete-log-stream \
      --log-group-name "$LOG_GROUP_NAME" \
      --log-stream-name "$s" \
      $REGION_FLAG
  done

  # Handle pagination
  next_token=$(echo "$output" | jq -r '.NextToken // empty')

  if [[ -z "$next_token" ]]; then
    break
  fi
done

echo
echo "All log streams deleted."