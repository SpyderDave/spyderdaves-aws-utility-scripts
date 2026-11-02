#!/usr/bin/env bash
# =============================================================================
# delete_cfn_stacks.sh
#
# Iterates every AWS Organizations member account, assumes the cross-account
# role, then searches every enabled region for CloudFormation stacks whose
# names match a given regex pattern and (optionally) deletes them.
#
# Usage:
#   ./delete_cfn_stacks.sh --pattern REGEX [OPTIONS]
#
# Required:
#   --pattern REGEX    Extended regex matched against the full stack name
#                      (grep -E). The script refuses to run without this to
#                      prevent accidental bulk deletion.
#
# Options:
#   --execute          Disable dry-run and actually delete stacks.
#   --force-delete-failed
#                      For matching stacks whose current status is
#                      DELETE_FAILED, delete using CloudFormation's
#                      FORCE_DELETE_STACK deletion mode, which skips
#                      resources that fail to delete instead of aborting.
#                      Those skipped resources are retained and become
#                      unmanaged — check the stack's resources afterward.
#   --role-name NAME   Cross-account role to assume
#                      (default: OrganizationAccountAccessRole)
#   --regions r1,r2    Comma-separated list of regions to check
#                      (default: all enabled regions)
#   --accounts a1,a2   Comma-separated list of account IDs to check
#                      (default: all active org member accounts)
#   --parallel N       Number of accounts to process in parallel (default: 5)
#   --log-file PATH    File to write full output to
#                      (default: cfn-cleanup-YYYYMMDD-HHMMSS.log)
#   --help             Show this help message
#
# Pattern examples:
#   --pattern '^myapp-'               prefix
#   --pattern '-prod$'                suffix
#   --pattern 'myapp'                 substring anywhere in name
#   --pattern '^(myapp|otherapp)-'    either prefix
#   --pattern '^myapp-.+-prod$'       prefix AND suffix
#   --pattern '^myapp-stack-[0-9]+$'  prefix with numeric suffix
#
# Prerequisites (all available in AWS CloudShell):
#   - aws CLI v2
#   - Credentials for the AWS Organizations management account
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
DRY_RUN=true
FORCE_DELETE_FAILED=false
ROLE_NAME="OrganizationAccountAccessRole"
STACK_PATTERN=""
REGIONS_OVERRIDE=""
ACCOUNTS_OVERRIDE=""
PARALLEL=5
LOG_FILE="cfn-cleanup-$(date '+%Y%m%d-%H%M%S').log"
CALLER_ACCOUNT=""   # set in main() once caller identity is known

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()      { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()     { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success()  { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
dryrun()   { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }
# progress() writes directly to the shared progress file, bypassing any
# per-job exec redirect so the parent's tail -f always sees these lines.
progress() { echo -e "[$(date '+%H:%M:%S')] $*" >> "$PROGRESS_FILE"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute)        DRY_RUN=false ;;
    --force-delete-failed) FORCE_DELETE_FAILED=true ;;
    --role-name)      ROLE_NAME="$2";        shift ;;
    --regions)        REGIONS_OVERRIDE="$2"; shift ;;
    --accounts)       ACCOUNTS_OVERRIDE="$2"; shift ;;
    --pattern)        STACK_PATTERN="$2";    shift ;;
    --parallel)       PARALLEL="$2";         shift ;;
    --log-file)       LOG_FILE="$2";         shift ;;
    --help|-h)        usage ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Validate required arguments ───────────────────────────────────────────────
if [[ -z "$STACK_PATTERN" ]]; then
  error "--pattern is required. Specify an extended regex to match stack names."
  error "Example: --pattern '^myapp-'"
  error "Run with --help for full usage."
  exit 1
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         CloudFormation Stack Cleanup (Org-wide)          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Pattern  : ${BOLD}${STACK_PATTERN}${RESET}"
echo -e "  Role     : ${ROLE_NAME}"
if $FORCE_DELETE_FAILED; then
  echo -e "  Force delete DELETE_FAILED stacks : ${BOLD}enabled${RESET}"
fi
echo

if $DRY_RUN; then
  warn "DRY-RUN MODE — no stacks will be deleted. Pass --execute to delete."
else
  warn "EXECUTE MODE — stacks matching '${STACK_PATTERN}' WILL be deleted."
  if $FORCE_DELETE_FAILED; then
    warn "Stacks currently in DELETE_FAILED state will be FORCE deleted —"
    warn "resources that fail to delete will be SKIPPED and RETAINED (unmanaged)."
  fi
  read -r -p "  Are you sure you want to continue? [yes/N]: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { log "Aborted."; exit 0; }
fi
echo

# ── Shared state files (used instead of pipes so subshells can write back) ───
TMPDIR_WORK=$(mktemp -d)
SUMMARY_FILE="${TMPDIR_WORK}/summary.txt"
PROGRESS_FILE="${TMPDIR_WORK}/progress.log"
STACKS_FILE="${TMPDIR_WORK}/stacks.txt"   # manifest of every stack found
touch "$SUMMARY_FILE" "$PROGRESS_FILE" "$STACKS_FILE"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ── Helper: assume role and export credentials into the current shell ─────────
# Call this only from within a subshell (background job) so the exports
# don't bleed back to the parent process.
assume_role_export() {
  local account_id="$1"
  local role_arn="arn:aws:iam::${account_id}:role/${ROLE_NAME}"

  local creds
  creds=$(aws sts assume-role \
    --role-arn "$role_arn" \
    --role-session-name "CFNCleanup-$(date +%s)" \
    --duration-seconds 3600 \
    --output json 2>/dev/null) || return 1

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID=$(echo "$creds"     | grep -o '"AccessKeyId": *"[^"]*"'     | awk -F'"' '{print $4}')
  AWS_SECRET_ACCESS_KEY=$(echo "$creds" | grep -o '"SecretAccessKey": *"[^"]*"'  | awk -F'"' '{print $4}')
  AWS_SESSION_TOKEN=$(echo "$creds"     | grep -o '"SessionToken": *"[^"]*"'     | awk -F'"' '{print $4}')

  # Validate we actually got values
  [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" && -n "$AWS_SESSION_TOKEN" ]]
}

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

# ── Helper: get all matching stacks in a region (handles pagination) ──────────
get_matching_stacks() {
  local region="$1"
  local next_token=""

  while true; do
    local args=(cloudformation list-stacks \
      --region "$region" \
      --stack-status-filter \
        CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        ROLLBACK_COMPLETE IMPORT_COMPLETE IMPORT_ROLLBACK_COMPLETE \
        DELETE_FAILED \
      --query "StackSummaries[].StackName" \
      --output text)
    [[ -n "$next_token" ]] && args+=(--next-token "$next_token")

    local page
    page=$(aws "${args[@]}" 2>/dev/null) || break

    # Filter by regex locally — grep -E gives full extended regex support
    echo "$page" | tr '\t' '\n' | grep -E "$STACK_PATTERN" || true

    next_token=$(aws cloudformation list-stacks \
      --region "$region" \
      --query 'NextToken' --output text 2>/dev/null || true)
    [[ "$next_token" == "None" || -z "$next_token" ]] && break
  done
}

# ── Helper: get a stack's current status ──────────────────────────────────────
get_stack_status() {
  local region="$1"
  local stack_name="$2"

  aws cloudformation describe-stacks \
    --region "$region" \
    --stack-name "$stack_name" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST"
}

# ── Helper: wait for stack deletion to complete ───────────────────────────────
wait_for_deletion() {
  local region="$1"
  local stack_name="$2"
  local max_wait=600   # 10 minutes
  local interval=15
  local elapsed=0

  while (( elapsed < max_wait )); do
    local status
    status=$(aws cloudformation describe-stacks \
      --region "$region" \
      --stack-name "$stack_name" \
      --query 'Stacks[0].StackStatus' \
      --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    case "$status" in
      DELETE_COMPLETE|DOES_NOT_EXIST)
        return 0 ;;
      DELETE_FAILED)
        return 1 ;;
    esac

    sleep "$interval"
    (( elapsed += interval ))
  done

  return 2  # timeout
}

# ── Per-account processing (runs as background job for parallelism) ────────────
process_account() {
  local account_id="$1"
  local account_name="$2"
  local regions=("${@:3}")

  local account_label="${account_id} (${account_name})"
  local region_found=0 region_deleted=0 region_failed=0

  # Redirect all verbose output for this job to a per-account log file.
  # progress() writes directly to PROGRESS_FILE and bypasses this redirect.
  local account_log="${TMPDIR_WORK}/account_${account_id}.log"
  exec > "$account_log" 2>&1

  # For the caller account itself, role assumption isn't possible (and isn't
  # needed) — use the ambient credentials. For every other account, assume the
  # cross-account role and export the temporary credentials into this subshell.
  # Safe because process_account is always called with & (runs as a background job).
  if [[ "$account_id" == "${CALLER_ACCOUNT:-}" ]]; then
    progress "${CYAN}[LOCAL]${RESET} ${account_label} — using caller credentials (no assume-role)"
  elif ! assume_role_export "$account_id"; then
    progress "${RED}[SKIP]${RESET} ${account_label} — could not assume role '${ROLE_NAME}'"
    echo "SKIP|${account_id}|${account_name}|assume_role_failed" >> "$SUMMARY_FILE"
    return
  fi

  progress "${CYAN}[START]${RESET} ${account_label} — checking ${#regions[@]} region(s)"

  for region in "${regions[@]}"; do
    mapfile -t stacks < <(get_matching_stacks "$region")

    # Skip region if no matching stacks
    if [[ ${#stacks[@]} -eq 0 ]] || [[ -z "${stacks[0]}" ]]; then
      continue
    fi

    for stack_name in "${stacks[@]}"; do
      [[ -z "$stack_name" ]] && continue
      (( region_found++ )) || true

      # Record to manifest immediately — independent of tail -f / tee timing
      echo "${account_id}|${account_name}|${region}|${stack_name}" >> "$STACKS_FILE"

      if $DRY_RUN; then
        local current_status
        current_status=$(get_stack_status "$region" "$stack_name")
        if [[ "$current_status" == "DELETE_FAILED" ]] && $FORCE_DELETE_FAILED; then
          progress "${YELLOW}[DRY-RUN]${RESET} ${account_label} — ${region}: would FORCE delete ${stack_name} (currently DELETE_FAILED)"
        else
          progress "${YELLOW}[DRY-RUN]${RESET} ${account_label} — ${region}: would delete ${stack_name}"
        fi
      else
        local current_status delete_args=(cloudformation delete-stack --region "$region" --stack-name "$stack_name")
        current_status=$(get_stack_status "$region" "$stack_name")

        if [[ "$current_status" == "DELETE_FAILED" ]] && $FORCE_DELETE_FAILED; then
          delete_args+=(--deletion-mode FORCE_DELETE_STACK)
          progress "${CYAN}[FORCE-DELETE]${RESET} ${account_label} — ${region}: force deleting ${stack_name} (was DELETE_FAILED) ..."
        else
          progress "${CYAN}[DELETE]${RESET} ${account_label} — ${region}: deleting ${stack_name} ..."
        fi

        if aws "${delete_args[@]}" 2>/dev/null; then
          if wait_for_deletion "$region" "$stack_name"; then
            progress "${GREEN}[DELETED]${RESET} ${account_label} — ${region}: ${stack_name}"
            (( region_deleted++ )) || true
          else
            progress "${RED}[FAILED]${RESET} ${account_label} — ${region}: deletion timed-out or failed for ${stack_name}"
            (( region_failed++ )) || true
          fi
        else
          progress "${RED}[FAILED]${RESET} ${account_label} — ${region}: could not initiate deletion of ${stack_name}"
          (( region_failed++ )) || true
        fi
      fi
    done
  done

  # Final per-account progress line
  if (( region_found == 0 )); then
    progress "${GREEN}[CLEAN]${RESET} ${account_label} — no matching stacks found"
  elif $DRY_RUN; then
    progress "${YELLOW}[DONE]${RESET} ${account_label} — ${region_found} stack(s) would be deleted"
  else
    progress "${GREEN}[DONE]${RESET} ${account_label} — ${region_found} found, ${region_deleted} deleted, ${region_failed} failed"
  fi

  # Append result for summary (echo >> is atomic for short lines on Linux)
  echo "RESULT|${account_id}|${account_name}|${region_found}|${region_deleted}|${region_failed}" \
    >> "$SUMMARY_FILE"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  # Tee all output (stdout + stderr) to the log file for the duration of main().
  # The log captures the banner, live progress lines (via tail -f → stdout), and summary.
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Full output is being logged to: ${LOG_FILE}"
  echo

  # Validate caller identity
  local caller_account
  caller_account=$(aws sts get-caller-identity --query 'Account' --output text)
  CALLER_ACCOUNT="$caller_account"
  log "Management account: ${caller_account}"

  # Fetch regions once from the management account
  log "Fetching enabled regions..."
  mapfile -t REGIONS < <(get_regions)
  log "Regions to check (${#REGIONS[@]}): ${REGIONS[*]}"
  echo

  # Build the list of accounts to process.
  # Initialise empty (=()) so the length checks below are safe under `set -u`.
  declare -a ACCOUNT_IDS=() ACCOUNT_NAMES=()

  if [[ -n "$ACCOUNTS_OVERRIDE" ]]; then
    # Specific accounts requested — skip the org-wide list-accounts call and
    # only look up the named accounts. Resolve each name individually.
    log "Using ${ACCOUNTS_OVERRIDE//,/ } from --accounts (skipping org-wide lookup)."
    local acct
    while IFS= read -r acct; do
      acct="$(echo "$acct" | tr -d '[:space:]')"
      [[ -z "$acct" ]] && continue
      local acct_name=""
      if [[ "$acct" == "$caller_account" ]]; then
        # The caller account itself can't be reached via assume-role; it will
        # be processed directly with the current credentials (see process_account).
        warn "Account ${acct} is the caller account — will process directly (no assume-role)."
        acct_name="caller-account"
      else
        acct_name=$(aws organizations describe-account \
          --account-id "$acct" \
          --query 'Account.Name' \
          --output text 2>/dev/null || true)
      fi
      [[ -z "$acct_name" || "$acct_name" == "None" ]] && acct_name="$acct"
      ACCOUNT_IDS+=("$acct")
      ACCOUNT_NAMES+=("$acct_name")
    done < <(echo "$ACCOUNTS_OVERRIDE" | tr ',' '\n')

    if [[ -z "${ACCOUNT_IDS[*]:-}" ]]; then
      warn "No valid accounts to process from --accounts."
      exit 0
    fi
  else
    # Fetch org accounts
    log "Fetching organization member accounts..."
    local -a RAW_ACCOUNTS=()
    mapfile -t RAW_ACCOUNTS < <(
      aws organizations list-accounts \
        --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' \
        --output text 2>/dev/null | grep -v "^${caller_account}"$'\t' || true
    )

    if [[ -z "${RAW_ACCOUNTS[*]:-}" ]]; then
      warn "No active member accounts found (check Organizations access)."
      exit 0
    fi

    # Parse into parallel arrays
    local row
    for row in "${RAW_ACCOUNTS[@]}"; do
      ACCOUNT_IDS+=("$(echo "$row" | awk '{print $1}')")
      ACCOUNT_NAMES+=("$(echo "$row" | cut -f2-)")
    done
  fi

  log "Found ${#ACCOUNT_IDS[@]} member account(s). Processing with parallelism=${PARALLEL}."
  echo

  # ── Start live progress display ───────────────────────────────────────────
  echo -e "${BOLD}──────────────────── LIVE PROGRESS ─────────────────────${RESET}"
  tail -f "$PROGRESS_FILE" &
  TAIL_PID=$!

  # Process accounts, up to $PARALLEL at a time
  local job_count=0
  local pids=()

  for i in "${!ACCOUNT_IDS[@]}"; do
    process_account "${ACCOUNT_IDS[$i]}" "${ACCOUNT_NAMES[$i]}" "${REGIONS[@]}" &
    pids+=($!)
    (( job_count++ )) || true

    if (( job_count >= PARALLEL )); then
      # Wait for one slot to free up
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
      (( job_count-- )) || true
    fi
  done

  # Wait for remaining jobs
  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  # Give tail a moment to flush the last lines, then stop it
  sleep 1
  kill "$TAIL_PID" 2>/dev/null
  wait "$TAIL_PID" 2>/dev/null
  echo -e "${BOLD}─────────────────────────────────────────────────────────${RESET}"

  # ── Summary ────────────────────────────────────────────────────────────────
  echo
  echo -e "${BOLD}════════════════════ SUMMARY ════════════════════${RESET}"

  local total_found=0 total_deleted=0 total_failed=0 total_skipped=0

  while IFS='|' read -r type acct name f d fail; do
    case "$type" in
      SKIP)
        warn "  SKIPPED  ${acct} (${name}) — could not assume role"
        (( total_skipped++ )) || true
        ;;
      RESULT)
        if (( f == 0 )); then
          log "  CLEAN    ${acct} (${name}) — no matching stacks"
        elif $DRY_RUN; then
          dryrun "  FOUND    ${acct} (${name}) — ${f} stack(s) would be deleted"
        else
          local status_label
          (( fail > 0 )) && status_label="${GREEN}${d} deleted${RESET}, ${RED}${fail} failed${RESET}" \
                          || status_label="${GREEN}${d} deleted${RESET}"
          echo -e "  DONE     ${acct} (${name}) — ${f} found, ${status_label}"
        fi
        (( total_found   += f    )) || true
        (( total_deleted += d    )) || true
        (( total_failed  += fail )) || true
        ;;
    esac
  done < "$SUMMARY_FILE"

  echo
  echo -e "  Pattern          : ${STACK_PATTERN}"
  echo -e "  Accounts skipped : ${total_skipped}"
  echo -e "  Stacks found     : ${total_found}"
  if $DRY_RUN; then
    echo -e "  ${YELLOW}(Dry-run — no stacks were deleted. Re-run with --execute to delete.)${RESET}"
  else
    echo -e "  Stacks deleted   : ${total_deleted}"
    echo -e "  Stacks failed    : ${total_failed}"
  fi
  echo -e "${BOLD}═════════════════════════════════════════════════${RESET}"

  # ── Stack manifest ─────────────────────────────────────────────────────────
  # Written directly by background jobs, so it's complete regardless of any
  # tail -f / tee timing.  Always printed; always captured in the log file.
  echo
  if [[ ! -s "$STACKS_FILE" ]]; then
    echo -e "${BOLD}══════════════════ STACK MANIFEST ═══════════════${RESET}"
    echo -e "  (no matching stacks found across all accounts)"
    echo -e "${BOLD}═════════════════════════════════════════════════${RESET}"
  else
    local action_label
    $DRY_RUN && action_label="WOULD DELETE" || action_label="DELETED / ATTEMPTED"

    echo -e "${BOLD}══════════════════ STACK MANIFEST ═══════════════${RESET}"
    echo -e "  ${action_label} — $(wc -l < "$STACKS_FILE" | tr -d ' ') stack(s) total"
    echo -e "${BOLD}─────────────────────────────────────────────────${RESET}"
    printf "  %-14s  %-24s  %-20s  %s\n" "ACCOUNT ID" "ACCOUNT NAME" "REGION" "STACK NAME"
    printf "  %-14s  %-24s  %-20s  %s\n" "--------------" "------------------------" "--------------------" "----------"
    while IFS='|' read -r acct_id acct_name region stack; do
      printf "  %-14s  %-24s  %-20s  %s\n" "$acct_id" "$acct_name" "$region" "$stack"
    done < "$STACKS_FILE"
    echo -e "${BOLD}═════════════════════════════════════════════════${RESET}"
  fi
}

main
