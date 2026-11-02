# THCP AWS Utility Scripts

A collection of utility scripts for administering and cleaning up resources across an
**AWS Organization**. Most scripts are designed to run from the **AWS CloudShell** (or any
shell with the AWS CLI configured) in the **management / payer account**, where they
enumerate member accounts via AWS Organizations and assume a cross-account role into each
one to perform their work.

> ⚠️ **Many of these scripts delete resources.** Read the synopsis for each script before
> running it. Where a `DRY_RUN` / dry-run mode exists, use it first.

---

## Common conventions

- **Cross-account role:** Most org-wide scripts assume `OrganizationAccountAccessRole` in
  each member account via `aws sts assume-role`. This role must exist and be assumable from
  the account you run the script in.
- **Account discovery:** Org-wide scripts call `aws organizations list-accounts` and operate
  only on accounts with `Status == ACTIVE`.
- **Prerequisites:** AWS CLI v2 and (for several scripts) `jq`. All of these are available
  by default in AWS CloudShell.
- **Region:** Some scripts target a single hard-coded region; others iterate all
  enabled/opted-in regions. Check each synopsis.

---

## Scripts

### `cross-account-command-execute.sh`
Deletes **CloudWatch Log Groups** across every active account in the Organization whose name
contains a configured substring.

- **Config (edit at top of file):** `ROLE_NAME`, `MATCH_TEXT` (substring to match log group
  names against), `SESSION_NAME`, `REGION` (single region, default `us-east-1`).
- **Behaviour:** For each active account it assumes the cross-account role, lists log groups
  matching `MATCH_TEXT`, and deletes each one. Skips accounts where the role cannot be
  assumed.
- ⚠️ **No dry-run** — deletions are immediate. Despite the generic file name, this script is
  hard-wired to delete log groups; adjust `MATCH_TEXT` carefully.

### `delete-all-logstreams-in-loggroup.sh`
Deletes **all log streams inside a single CloudWatch Log Group** (the log group itself is
kept).

- **Usage:** `./delete-all-logstreams-in-loggroup.sh <log-group-name> [region]`
- **Behaviour:** Paginates through the log group's streams (50 at a time) and deletes each
  one. Region is optional.
- **Requires:** `jq`.
- ⚠️ **No dry-run.**

### `delete-buckets.sh`
Bulk-deletes **S3 buckets whose name starts with `pss-support`** in the current account.

- **Behaviour:** Lists matching buckets via `s3api list-buckets`, then calls
  `./delete_bucket.sh` (see below) for each one to empty and remove it.
- **Depends on:** `delete_bucket.sh` being present in the same directory.
- ⚠️ **No dry-run.** The `pss-support` prefix is hard-coded.

### `delete_bucket.sh`
Fully empties and deletes **one S3 bucket**, including all object versions and delete markers
(works on versioned buckets).

- **Usage:** `./delete_bucket.sh <bucket-name>`
- **Behaviour:** Suspends bucket versioning, deletes every object version and delete marker
  (using `jq` to walk `list-object-versions`), then runs `aws s3 rb --force` to remove the
  bucket.
- **Requires:** `jq`.
- **Used by:** `delete-buckets.sh`.
- ⚠️ **No dry-run — destructive and irreversible.**

### `delete-configrecorders-and-deliverychannels.sh`
Removes **AWS Config** configuration recorders and delivery channels across **all enabled
regions** in the current account.

- **Behaviour:** Iterates every region from `ec2 describe-regions`; for each, deletes any
  Config delivery channels and configuration recorders found. Useful when decommissioning
  AWS Config or cleaning up before re-deploying it via an org baseline.
- ⚠️ **No dry-run.** Runs against a single account (the one whose credentials are active).

### `delete_cfn_stacks.sh`
The most full-featured script: searches **every member account and every enabled region**
for **CloudFormation stacks** whose name matches a regex, and optionally deletes them.
Runs in parallel with a live progress display, summary, and stack manifest.

- **Usage:** `./delete_cfn_stacks.sh --pattern REGEX [OPTIONS]`
- **Required:** `--pattern REGEX` — an extended (`grep -E`) regex matched against the full
  stack name. The script refuses to run without it, to prevent accidental bulk deletion.
- **Key options:**
  - `--execute` — actually delete (default is **dry-run**; prompts for `yes` confirmation in
    execute mode).
  - `--role-name NAME` — cross-account role (default `OrganizationAccountAccessRole`).
  - `--regions r1,r2` — limit to specific regions (default: all enabled).
  - `--accounts a1,a2` — limit to specific account IDs (default: all active members).
  - `--parallel N` — accounts processed concurrently (default 5).
  - `--log-file PATH` — full output log (default `cfn-cleanup-<timestamp>.log`).
  - `--help` — full usage.
- **Pattern examples:** `'^myapp-'` (prefix), `'-prod$'` (suffix), `'myapp'` (substring),
  `'^(myapp|otherapp)-'`.
- **Behaviour:** Defaults to **dry-run**, waits for each stack's deletion to complete
  (up to 10 min), and prints a summary plus a full manifest of every matching stack found.
- ✅ **Safe by default** (dry-run); requires explicit `--execute` to delete.

### `find-domain-across-org.sh`
Searches **every active account** for a **Route 53 hosted zone** matching a target domain.
Read-only — does not modify anything.

- **Config (edit at top of file):** `TARGET_DOMAIN` (default `lifeworks.com`), `ROLE_NAME`,
  `REGION`.
- **Behaviour:** Assumes the cross-account role in each account and lists hosted zones,
  reporting which account(s) contain a zone for the target domain (and its Hosted Zone ID).
- ✅ **Non-destructive.**

### `iam-and-ebs-snapshot-cleanup.sh`
A **two-phase (mark-then-delete) cleanup** of old **AMIs** and **orphaned EBS snapshots**
across all enabled regions in the current account.

- **Config (edit at top of file):** `RETENTION_DAYS` (default 1095 / 3 years),
  `GRACE_PERIOD_DAYS` (default 30), `DRY_RUN` (default `true`).
- **Behaviour:**
  - **Phase 1 (mark):** AMIs/snapshots older than the retention cutoff that are not in use
    are tagged `PendingDeletion=true` with a `PendingDeletionDate`.
  - **Phase 2 (delete):** On a later run, items whose `PendingDeletionDate` is older than the
    grace period are deregistered/deleted.
  - **Safeguards:** Skips AMIs in use (by launch templates, launch configs, or running
    instances), snapshots referenced by any AMI, snapshots whose source volume still exists,
    and anything tagged `Keep=true`.
  - Logs everything to `ami-cleanup-<date>.log`.
- **Requires:** `jq`, and GNU `date` (`date -d`).
- ✅ **Safe by default** (`DRY_RUN=true`); set `DRY_RUN=false` to execute.

### `list-all-iam-users-with-console-access.sh`
Generates a **CSV security report of IAM users with console access** across every active
account in the Organization. Read-only.

- **Output:** `iam_console_user_security_report.csv` with columns: AccountId, AccountName,
  AccountOwner, UserName, ConsoleAccess, MFAEnabled, AccessKeyCount, PasswordLastUsed,
  CreateDate.
- **Behaviour:** For each account it reads the `AccountOwner` org tag, assumes the
  cross-account role, lists IAM users, and for those with a login profile records MFA status
  and access-key count. Preserves and restores the management-account credentials between
  accounts.
- **Prerequisite:** Run with management-account credentials available in the environment
  (`AWS_ACCESS_KEY_ID` etc.).
- ✅ **Non-destructive** (audit / reporting only).

### `root-user-credential-audit.sh`
> **Note:** Despite the `.sh` extension, this is a **Python 3 script** (uses `boto3`).
> Run it with `python3 root-user-credential-audit.sh`.

Audits the **root user credential posture** of every active account in the Organization and
writes a CSV. Read-only.

- **Output:** `root_credential_audit.csv` with columns: AccountId, AccountName,
  PasswordEnabled, MFAEnabled, AccessKey1Active, AccessKey2Active.
- **Behaviour:** Assumes the cross-account role into each account, generates and fetches the
  IAM credential report, parses the `<root_account>` row, and records whether the root user
  has a password, MFA, and active access keys.
- **Requires:** Python 3 and `boto3`.
- ✅ **Non-destructive** (audit / reporting only).

---

## Safety summary

| Script | Scope | Destructive? | Dry-run / Safe default |
|---|---|---|---|
| `cross-account-command-execute.sh` | Org-wide | ✅ Deletes log groups | ❌ No |
| `delete-all-logstreams-in-loggroup.sh` | Single account | ✅ Deletes log streams | ❌ No |
| `delete-buckets.sh` | Single account | ✅ Deletes S3 buckets | ❌ No |
| `delete_bucket.sh` | Single account | ✅ Deletes one S3 bucket | ❌ No |
| `delete-configrecorders-and-deliverychannels.sh` | Single account, all regions | ✅ Deletes AWS Config | ❌ No |
| `delete_cfn_stacks.sh` | Org-wide, all regions | ✅ Deletes CFN stacks | ✅ Yes (dry-run default) |
| `find-domain-across-org.sh` | Org-wide | ❌ Read-only | ✅ N/A |
| `iam-and-ebs-snapshot-cleanup.sh` | Single account, all regions | ✅ Deletes AMIs/snapshots | ✅ Yes (`DRY_RUN=true`) |
| `list-all-iam-users-with-console-access.sh` | Org-wide | ❌ Read-only (CSV report) | ✅ N/A |
| `root-user-credential-audit.sh` (Python) | Org-wide | ❌ Read-only (CSV report) | ✅ N/A |
