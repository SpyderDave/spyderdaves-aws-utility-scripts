#!/bin/bash
set -euo pipefail

# --- CONFIG ---
RETENTION_DAYS=1095              # 3 years
GRACE_PERIOD_DAYS=30             # wait before deletion
DRY_RUN=true                     # set to false to execute
LOG_FILE="ami-cleanup-$(date +%F).log"

echo "Starting AMI + orphaned snapshot cleanup (two-phase)" | tee -a "$LOG_FILE"
echo "Retention: $RETENTION_DAYS days | Grace: $GRACE_PERIOD_DAYS days | Dry run: $DRY_RUN" | tee -a "$LOG_FILE"

CUTOFF_DATE=$(date -u -d "$RETENTION_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)
GRACE_CUTOFF=$(date -u -d "$GRACE_PERIOD_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)

normalize() {
  tr '\t' '\n' | grep -v "^None$" | grep -v "^$" | sort -u
}

# --- GET ALL ENABLED REGIONS ---
REGIONS=$(aws ec2 describe-regions \
  --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
  --query "Regions[].RegionName" \
  --output text | tr '\t' '\n')

echo "Regions to process:" | tee -a "$LOG_FILE"
echo "$REGIONS" | tee -a "$LOG_FILE"

# ============================================================
# PROCESS EACH REGION
# ============================================================
for REGION in $REGIONS; do
  echo "" | tee -a "$LOG_FILE"
  echo "========================================" | tee -a "$LOG_FILE"
  echo "REGION: $REGION" | tee -a "$LOG_FILE"
  echo "========================================" | tee -a "$LOG_FILE"

  # --- COLLECT IN-USE AMIs ---
  echo "Collecting in-use AMIs..." | tee -a "$LOG_FILE"

  LT_AMIS=$(aws ec2 describe-launch-template-versions \
    --region "$REGION" \
    --query "LaunchTemplateVersions[].LaunchTemplateData.ImageId" \
    --output text | normalize)

  LC_AMIS=$(aws autoscaling describe-launch-configurations \
    --region "$REGION" \
    --query "LaunchConfigurations[].ImageId" \
    --output text | normalize)

  INSTANCE_AMIS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --query "Reservations[].Instances[].ImageId" \
    --output text | normalize)

  IN_USE_AMIS=$(echo -e "$LT_AMIS\n$LC_AMIS\n$INSTANCE_AMIS" | normalize)

  # --- COLLECT SNAPSHOT IDs REFERENCED BY ANY AMI IN THIS REGION ---
  # Used later to identify truly orphaned snapshots
  AMI_SNAPSHOT_IDS=$(aws ec2 describe-images \
    --owners self \
    --region "$REGION" \
    --query "Images[].BlockDeviceMappings[].Ebs.SnapshotId" \
    --output text | normalize)

  # --- GET ALL OLD AMIs ---
  AMIS_JSON=$(aws ec2 describe-images \
    --owners self \
    --region "$REGION" \
    --query "Images[?CreationDate<='$CUTOFF_DATE']" \
    --output json)

  echo "$AMIS_JSON" | jq -c '.[]' | while read -r AMI; do
    AMI_ID=$(echo "$AMI" | jq -r '.ImageId')
    NAME=$(echo "$AMI" | jq -r '.Name')

    echo "----------------------------------------" | tee -a "$LOG_FILE"
    echo "Evaluating AMI: $AMI_ID ($NAME) [$REGION]" | tee -a "$LOG_FILE"

    # Skip if in use
    if echo "$IN_USE_AMIS" | grep -q "^$AMI_ID$"; then
      echo "SKIP: In use" | tee -a "$LOG_FILE"
      continue
    fi

    # Skip if Keep=true
    KEEP=$(echo "$AMI" | jq -r '.Tags[]? | select(.Key=="Keep") | .Value' || true)
    if [[ "$KEEP" == "true" ]]; then
      echo "SKIP: Keep=true tag present" | tee -a "$LOG_FILE"
      continue
    fi

    PD_TAG=$(echo "$AMI" | jq -r '.Tags[]? | select(.Key=="PendingDeletion") | .Value' || true)
    PD_DATE=$(echo "$AMI" | jq -r '.Tags[]? | select(.Key=="PendingDeletionDate") | .Value' || true)

    # --- PHASE 1: MARK ---
    if [[ -z "$PD_TAG" || "$PD_TAG" == "null" ]]; then
      echo "PHASE 1: Marking AMI for deletion" | tee -a "$LOG_FILE"
      if [[ "$DRY_RUN" == "false" ]]; then
        aws ec2 create-tags \
          --resources "$AMI_ID" \
          --tags Key=PendingDeletion,Value=true Key=PendingDeletionDate,Value="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --region "$REGION"
      else
        echo "[DRY RUN] Would tag AMI $AMI_ID" | tee -a "$LOG_FILE"
      fi
      continue
    fi

    # --- PHASE 2: DELETE ---
    if [[ -n "$PD_DATE" && "$PD_DATE" < "$GRACE_CUTOFF" ]]; then
      echo "PHASE 2: Deleting AMI after grace period" | tee -a "$LOG_FILE"
      SNAPSHOTS=$(aws ec2 describe-images \
        --image-ids "$AMI_ID" \
        --region "$REGION" \
        --query "Images[].BlockDeviceMappings[].Ebs.SnapshotId" \
        --output text)

      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would deregister AMI: $AMI_ID" | tee -a "$LOG_FILE"
        echo "[DRY RUN] Would delete snapshots: $SNAPSHOTS" | tee -a "$LOG_FILE"
        continue
      fi

      aws ec2 deregister-image --image-id "$AMI_ID" --region "$REGION"
      for SNAP_ID in $SNAPSHOTS; do
        if [[ "$SNAP_ID" != "None" && -n "$SNAP_ID" ]]; then
          aws ec2 delete-snapshot --snapshot-id "$SNAP_ID" --region "$REGION"
          echo "Deleted snapshot: $SNAP_ID" | tee -a "$LOG_FILE"
        fi
      done
    else
      echo "WAIT: Still within grace period" | tee -a "$LOG_FILE"
    fi
  done

  # ============================================================
  # ORPHANED SNAPSHOT CLEANUP
  # A snapshot is orphaned if:
  #   - owned by self
  #   - older than CUTOFF_DATE
  #   - not referenced by any AMI (including ones newer than cutoff)
  #   - not currently attached to a volume (no active volume association)
  # ============================================================
  echo "" | tee -a "$LOG_FILE"
  echo "--- Orphaned Snapshot Cleanup [$REGION] ---" | tee -a "$LOG_FILE"

  # Collect ALL snapshot IDs referenced by ANY self-owned AMI (not just old ones)
  ALL_AMI_SNAPS=$(aws ec2 describe-images \
    --owners self \
    --region "$REGION" \
    --query "Images[].BlockDeviceMappings[].Ebs.SnapshotId" \
    --output text | normalize)

  # Get old self-owned snapshots
  OLD_SNAPS_JSON=$(aws ec2 describe-snapshots \
    --owner-ids self \
    --region "$REGION" \
    --query "Snapshots[?StartTime<='$CUTOFF_DATE']" \
    --output json)

  echo "$OLD_SNAPS_JSON" | jq -c '.[]' | while read -r SNAP; do
    SNAP_ID=$(echo "$SNAP" | jq -r '.SnapshotId')
    SNAP_DESC=$(echo "$SNAP" | jq -r '.Description')
    SNAP_DATE=$(echo "$SNAP" | jq -r '.StartTime')
    SNAP_VOL=$(echo "$SNAP" | jq -r '.VolumeId')

    echo "----------------------------------------" | tee -a "$LOG_FILE"
    echo "Evaluating snapshot: $SNAP_ID ($SNAP_DESC) [$REGION]" | tee -a "$LOG_FILE"

    # Skip if referenced by any AMI
    if echo "$ALL_AMI_SNAPS" | grep -q "^$SNAP_ID$"; then
      echo "SKIP: Referenced by an AMI" | tee -a "$LOG_FILE"
      continue
    fi

    # Skip if Keep=true
    KEEP=$(echo "$SNAP" | jq -r '.Tags[]? | select(.Key=="Keep") | .Value' || true)
    if [[ "$KEEP" == "true" ]]; then
      echo "SKIP: Keep=true tag present" | tee -a "$LOG_FILE"
      continue
    fi

    # Check if the source volume still exists (not orphaned from a live volume)
    # A vol-* ID that still exists means the snapshot may still be intentional
    if [[ "$SNAP_VOL" != "vol-ffffffff" && -n "$SNAP_VOL" && "$SNAP_VOL" != "null" ]]; then
      VOL_EXISTS=$(aws ec2 describe-volumes \
        --volume-ids "$SNAP_VOL" \
        --region "$REGION" \
        --query "Volumes[].VolumeId" \
        --output text 2>/dev/null || true)
      if [[ -n "$VOL_EXISTS" ]]; then
        echo "SKIP: Source volume $SNAP_VOL still exists" | tee -a "$LOG_FILE"
        continue
      fi
    fi

    PD_TAG=$(echo "$SNAP" | jq -r '.Tags[]? | select(.Key=="PendingDeletion") | .Value' || true)
    PD_DATE=$(echo "$SNAP" | jq -r '.Tags[]? | select(.Key=="PendingDeletionDate") | .Value' || true)

    # --- PHASE 1: MARK ---
    if [[ -z "$PD_TAG" || "$PD_TAG" == "null" ]]; then
      echo "PHASE 1: Marking orphaned snapshot for deletion" | tee -a "$LOG_FILE"
      if [[ "$DRY_RUN" == "false" ]]; then
        aws ec2 create-tags \
          --resources "$SNAP_ID" \
          --tags Key=PendingDeletion,Value=true Key=PendingDeletionDate,Value="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --region "$REGION"
      else
        echo "[DRY RUN] Would tag snapshot $SNAP_ID" | tee -a "$LOG_FILE"
      fi
      continue
    fi

    # --- PHASE 2: DELETE ---
    if [[ -n "$PD_DATE" && "$PD_DATE" < "$GRACE_CUTOFF" ]]; then
      echo "PHASE 2: Deleting orphaned snapshot after grace period" | tee -a "$LOG_FILE"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] Would delete snapshot: $SNAP_ID" | tee -a "$LOG_FILE"
      else
        aws ec2 delete-snapshot --snapshot-id "$SNAP_ID" --region "$REGION"
        echo "Deleted orphaned snapshot: $SNAP_ID" | tee -a "$LOG_FILE"
      fi
    else
      echo "WAIT: Still within grace period" | tee -a "$LOG_FILE"
    fi
  done

done

echo "" | tee -a "$LOG_FILE"
echo "Two-phase AMI + orphaned snapshot cleanup complete." | tee -a "$LOG_FILE"