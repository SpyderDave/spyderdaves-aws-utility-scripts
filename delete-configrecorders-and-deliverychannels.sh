#!/bin/bash
# This script checks for AWS Config recorders and delivery channels
# across all regions and deletes them if they exist.

set -euo pipefail

# Get all enabled AWS regions
regions=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text)

# Regions to skip
skip_regions=("me-central-1" "me-south-1")

for region in $regions; do
  skip=false
  for skip_region in "${skip_regions[@]}"; do
    if [[ "$region" == "$skip_region" ]]; then
      skip=true
      break
    fi
  done
  if [[ "$skip" == true ]]; then
    echo "Skipping region: $region"
    echo "----"
    continue
  fi

  echo "Checking region: $region"

  # Check for config recorders (must be stopped and deleted before the
  # delivery channel, otherwise delete-delivery-channel fails with
  # LastDeliveryChannelDeleteFailedException)
  recorders=$(aws configservice describe-configuration-recorders --region "$region" --query "ConfigurationRecorders[].name" --output text 2>/dev/null || true)
  if [[ -n "$recorders" ]]; then
    for rec in $recorders; do
      echo "Stopping config recorder: $rec in $region"
      aws configservice stop-configuration-recorder --configuration-recorder-name "$rec" --region "$region"
      echo "Deleting config recorder: $rec in $region"
      aws configservice delete-configuration-recorder --configuration-recorder-name "$rec" --region "$region"
    done
  else
    echo "No config recorders in $region"
  fi

  # Check for delivery channels
  delivery_channels=$(aws configservice describe-delivery-channels --region "$region" --query "DeliveryChannels[].name" --output text 2>/dev/null || true)
  if [[ -n "$delivery_channels" ]]; then
    for dc in $delivery_channels; do
      echo "Deleting delivery channel: $dc in $region"
      aws configservice delete-delivery-channel --delivery-channel-name "$dc" --region "$region"
    done
  else
    echo "No delivery channels in $region"
  fi

  echo "----"
done

echo "Completed AWS Config cleanup across all regions." 