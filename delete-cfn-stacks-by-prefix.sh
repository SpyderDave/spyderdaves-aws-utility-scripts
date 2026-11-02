#!/usr/bin/env bash
# =============================================================================
# delete-cfn-stacks-by-prefix.sh
#
# Finds CloudFormation stacks whose name starts with a given prefix across
# all enabled regions in the current AWS account, then prompts for
# confirmation before deleting them. Intended to be run directly in AWS
# CloudShell using the ambient credentials of the account being cleaned up
# (no cross-account role assumption).
#
# Usage:
#   ./delete-cfn-stacks-by-prefix.sh --prefix PREFIX [OPTIONS]
#
# Required:
#   --prefix PREFIX    Stacks whose name starts with this string are
#                       targeted for deletion.
#
# Options:
#   --regions r1,r2    Comma-separated list of regions to check
#                       (default: all enabled regions)
#   --yes              Skip the interactive confirmation prompt
#   --help             Show this help message
#
# Prerequisites (available by default in AWS CloudShell):
#   - aws CLI v2
#   - jq
# =============================================================================

set -euo pipefail

PREFIX=""
REGIONS_OVERRIDE=""
ASSUME_YES=false

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)  PREFIX="$2";           shift ;;
    --regions) REGIONS_OVERRIDE="$2"; shift ;;
    --yes)     ASSUME_YES=true ;;
    --help|-h) usage ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$PREFIX" ]]; then
  error "--prefix is required."
  error "Example: --prefix 'myapp-'"
  error "Run with --help for full usage."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  error "jq is required but was not found on PATH."
  exit 1
fi

# ── Helper: get all enabled regions ──────────────────────────────────────────
get_regions() {
  if [[ -n "$REGIONS_OVERRIDE" ]]; then
    echo "$REGIONS_OVERRIDE" | tr ',' '\n'
  else
    aws ec2 describe-regions \
      --filters Name=opt-in-status,Values=opted-in,opt-in-not-required \
      --query 'Regions[].RegionName' \
      --output text | tr '\t' '\n' | sort
  fi
}

# ── Helper: print matching stack names in a region, one per line ─────────────
# Handles pagination itself; each page's NextToken comes from the same
# response used to pull the stack names, so it's always accurate.
get_matching_stacks() {
  local region="$1"
  local next_token=""
  local response

  while true; do
    local args=(cloudformation list-stacks --region "$region" --output json)
    [[ -n "$next_token" ]] && args+=(--next-token "$next_token")

    response=$(aws "${args[@]}" 2>/dev/null) || break

    echo "$response" | jq -r --arg prefix "$PREFIX" \
      '.StackSummaries[] | select(.StackName | startswith($prefix)) | .StackName'

    next_token=$(echo "$response" | jq -r '.NextToken // empty')
    [[ -z "$next_token" ]] && break
  done
}

get_stack_status() {
  local region="$1" stack_name="$2"
  aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST"
}

main() {
  log "Account : $(aws sts get-caller-identity --query 'Account' --output text)"
  log "Prefix  : ${PREFIX}"

  log "Fetching enabled regions..."
  mapfile -t REGIONS < <(get_regions)
  log "Regions to check (${#REGIONS[@]}): ${REGIONS[*]}"
  echo

  log "Searching for stacks named '${PREFIX}*' across all regions..."
  declare -a FOUND_REGIONS=() FOUND_STACKS=()

  for region in "${REGIONS[@]}"; do
    local stacks
    mapfile -t stacks < <(get_matching_stacks "$region")
    for stack_name in "${stacks[@]}"; do
      [[ -z "$stack_name" ]] && continue
      FOUND_REGIONS+=("$region")
      FOUND_STACKS+=("$stack_name")
    done
  done

  echo
  if [[ ${#FOUND_STACKS[@]} -eq 0 ]]; then
    success "No stacks found matching prefix '${PREFIX}'."
    exit 0
  fi

  echo -e "${BOLD}Stacks matching prefix '${PREFIX}':${RESET}"
  printf "  %-20s  %s\n" "REGION" "STACK NAME"
  printf "  %-20s  %s\n" "--------------------" "----------"
  for i in "${!FOUND_STACKS[@]}"; do
    printf "  %-20s  %s\n" "${FOUND_REGIONS[$i]}" "${FOUND_STACKS[$i]}"
  done
  echo
  warn "${#FOUND_STACKS[@]} stack(s) will be PERMANENTLY DELETED."

  if ! $ASSUME_YES; then
    read -r -p "Type 'yes' to continue: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { log "Aborted. No stacks were deleted."; exit 0; }
  fi
  echo

  log "Initiating deletion..."
  for i in "${!FOUND_STACKS[@]}"; do
    region="${FOUND_REGIONS[$i]}"; stack_name="${FOUND_STACKS[$i]}"
    if aws cloudformation delete-stack --region "$region" --stack-name "$stack_name" 2>/dev/null; then
      log "  Delete initiated: ${stack_name} (${region})"
    else
      error "  Failed to initiate delete: ${stack_name} (${region})"
    fi
  done
  echo

  log "Waiting for deletions to complete..."
  declare -a PENDING_IDX=()
  for i in "${!FOUND_STACKS[@]}"; do PENDING_IDX+=("$i"); done

  local max_wait=900 interval=15 elapsed=0
  while [[ ${#PENDING_IDX[@]} -gt 0 && $elapsed -lt $max_wait ]]; do
    declare -a STILL_PENDING=()
    for i in "${PENDING_IDX[@]}"; do
      region="${FOUND_REGIONS[$i]}"; stack_name="${FOUND_STACKS[$i]}"
      status=$(get_stack_status "$region" "$stack_name")
      case "$status" in
        DELETE_COMPLETE|DOES_NOT_EXIST)
          success "  Deleted: ${stack_name} (${region})" ;;
        DELETE_FAILED)
          error "  DELETE_FAILED: ${stack_name} (${region}) — check the stack events in the console." ;;
        *)
          STILL_PENDING+=("$i") ;;
      esac
    done
    if [[ ${#STILL_PENDING[@]} -gt 0 ]]; then
      PENDING_IDX=("${STILL_PENDING[@]}")
      sleep "$interval"
      (( elapsed += interval )) || true
    else
      PENDING_IDX=()
    fi
  done

  if [[ ${#PENDING_IDX[@]} -gt 0 ]]; then
    warn "Timed out waiting on ${#PENDING_IDX[@]} stack(s) — they may still be deleting:"
    for i in "${PENDING_IDX[@]}"; do
      warn "  ${FOUND_STACKS[$i]} (${FOUND_REGIONS[$i]})"
    done
  fi

  echo
  success "Done."
}

main
