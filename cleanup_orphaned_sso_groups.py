#!/usr/bin/env python3
"""
Clean up orphaned AWS IAM Identity Center groups that were pushed from Okta
(Push Groups) and later deleted in Okta.

Logic:
  1. List AWS Identity Store groups whose DisplayName starts with --prefix.
  2. Check whether each group still exists in Okta (exact name match).
  3. For groups missing from Okta, check AWS for any assignments
     (account assignments / permission sets, and application assignments).
  4. Delete the group only if it has NO assignments. Dry-run is the DEFAULT;
     pass --execute to actually delete.

Fail-safe: any error while checking Okta or assignments for a group means that
group is SKIPPED (never deleted) and the error is logged.

Environment:
  OKTA_ORG_URL    e.g. https://yourorg.okta.com
  OKTA_API_TOKEN  SSWS token with okta.groups.read (read-only is enough)
  AWS credentials via the standard boto3 chain (--profile / env / role).
  Run in the management account or the delegated admin account for
  IAM Identity Center (required for list_account_assignments_for_principal).

Required IAM permissions:
  sso:ListInstances, sso:ListAccountAssignmentsForPrincipal,
  sso:ListApplicationAssignmentsForPrincipal,
  identitystore:ListGroups, identitystore:DeleteGroup

Usage:
  python cleanup_orphaned_sso_groups.py --prefix aws- --region ca-central-1            # dry run
  python cleanup_orphaned_sso_groups.py --prefix aws- --region ca-central-1 --execute  # delete
"""
import argparse
import csv
import logging
import os
import sys
import time
from datetime import datetime
from logging.handlers import RotatingFileHandler

import boto3
import requests
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

log = logging.getLogger("sso-cleanup")


# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #
def setup_logging(log_file: str, verbose: bool) -> None:
    log.setLevel(logging.DEBUG)
    fmt = logging.Formatter("%(asctime)s %(levelname)-8s %(message)s")

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.DEBUG if verbose else logging.INFO)
    console.setFormatter(fmt)

    fileh = RotatingFileHandler(log_file, maxBytes=10_000_000, backupCount=5, encoding="utf-8")
    fileh.setLevel(logging.DEBUG)
    fileh.setFormatter(fmt)

    log.addHandler(console)
    log.addHandler(fileh)


# --------------------------------------------------------------------------- #
# Okta
# --------------------------------------------------------------------------- #
class OktaClient:
    def __init__(self, org_url: str, token: str, timeout: int = 30, max_retries: int = 5):
        self.base = org_url.rstrip("/")
        self.timeout = timeout
        self.max_retries = max_retries
        self.session = requests.Session()
        self.session.headers.update(
            {"Authorization": f"SSWS {token}", "Accept": "application/json"}
        )

    def _get(self, url: str, params: dict | None = None) -> requests.Response:
        for attempt in range(1, self.max_retries + 1):
            try:
                resp = self.session.get(url, params=params, timeout=self.timeout)
            except requests.RequestException as exc:
                log.warning("Okta request error (attempt %d/%d): %s", attempt, self.max_retries, exc)
                if attempt == self.max_retries:
                    raise
                time.sleep(2 ** attempt)
                continue

            if resp.status_code == 429:
                reset = resp.headers.get("X-Rate-Limit-Reset")
                wait = max(int(reset) - int(time.time()), 1) + 1 if reset else 2 ** attempt
                log.warning("Okta rate limited (429); sleeping %ds", wait)
                time.sleep(wait)
                continue
            if resp.status_code >= 500:
                log.warning("Okta %d (attempt %d/%d)", resp.status_code, attempt, self.max_retries)
                if attempt == self.max_retries:
                    resp.raise_for_status()
                time.sleep(2 ** attempt)
                continue

            resp.raise_for_status()
            return resp
        raise RuntimeError(f"Okta request failed after {self.max_retries} attempts: {url}")

    def group_names_with_prefix(self, prefix: str) -> set[str]:
        """Return all Okta group names starting with prefix (casefolded)."""
        names: set[str] = set()
        url = f"{self.base}/api/v1/groups"
        params = {"q": prefix, "limit": 200}  # q = startsWith on profile.name
        pages = 0
        while url:
            resp = self._get(url, params)
            for g in resp.json():
                name = g.get("profile", {}).get("name")
                if name:
                    names.add(name.casefold())
            pages += 1
            url = resp.links.get("next", {}).get("url")
            params = None  # next link already contains query params
        log.info("Fetched %d Okta groups matching prefix %r (%d pages)", len(names), prefix, pages)
        return names


# --------------------------------------------------------------------------- #
# AWS
# --------------------------------------------------------------------------- #
class AwsSso:
    def __init__(self, profile: str | None, region: str | None, identity_store_id: str | None):
        session = boto3.Session(profile_name=profile, region_name=region)
        cfg = Config(retries={"max_attempts": 10, "mode": "adaptive"})
        self.sso = session.client("sso-admin", config=cfg)
        self.ids = session.client("identitystore", config=cfg)

        if identity_store_id:
            self.identity_store_id = identity_store_id
            # still need the instance ARN for assignment lookups
            inst = self._pick_instance()
            self.instance_arn = inst["InstanceArn"]
        else:
            inst = self._pick_instance()
            self.instance_arn = inst["InstanceArn"]
            self.identity_store_id = inst["IdentityStoreId"]
        log.info("Using Identity Store %s / instance %s", self.identity_store_id, self.instance_arn)

    def _pick_instance(self) -> dict:
        instances = self.sso.list_instances()["Instances"]
        if not instances:
            raise RuntimeError("No IAM Identity Center instance found in this region/account")
        if len(instances) > 1:
            log.warning("Multiple instances found; using the first")
        return instances[0]

    def groups_with_prefix(self, prefix: str) -> list[dict]:
        out = []
        pager = self.ids.get_paginator("list_groups")
        for page in pager.paginate(IdentityStoreId=self.identity_store_id):
            for g in page["Groups"]:
                if g.get("DisplayName", "").startswith(prefix):
                    out.append(g)
        log.info("Found %d AWS groups with prefix %r", len(out), prefix)
        return out

    def has_assignments(self, group_id: str) -> tuple[bool, str]:
        """Return (has_any, detail). Raises on API failure (caller skips group)."""
        # 1. Account assignments (permission sets)
        pager = self.sso.get_paginator("list_account_assignments_for_principal")
        for page in pager.paginate(
            InstanceArn=self.instance_arn, PrincipalId=group_id, PrincipalType="GROUP"
        ):
            if page["AccountAssignments"]:
                a = page["AccountAssignments"][0]
                return True, f"account assignment (account {a['AccountId']}, {a['PermissionSetArn']})"

        # 2. Customer-managed / AWS-managed application assignments
        pager = self.sso.get_paginator("list_application_assignments_for_principal")
        for page in pager.paginate(
            InstanceArn=self.instance_arn, PrincipalId=group_id, PrincipalType="GROUP"
        ):
            if page["ApplicationAssignments"]:
                a = page["ApplicationAssignments"][0]
                return True, f"application assignment ({a['ApplicationArn']})"

        return False, "no assignments"

    def delete_group(self, group_id: str) -> None:
        self.ids.delete_group(IdentityStoreId=self.identity_store_id, GroupId=group_id)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--prefix", required=True, help="AWS group DisplayName prefix to evaluate (required)")
    p.add_argument("--okta-prefix", help="Okta name prefix for lookup (default: same as --prefix)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--region", help="AWS region of the Identity Center instance")
    p.add_argument("--identity-store-id", help="Identity Store ID (default: auto-discover)")
    p.add_argument("--okta-url", default=os.environ.get("OKTA_ORG_URL"), help="Okta org URL (or OKTA_ORG_URL)")
    p.add_argument("--execute", action="store_true", help="Actually delete groups (default is dry-run)")
    p.add_argument("--dry-run", action="store_true", help="Explicit dry-run (this is already the default)")
    p.add_argument("--max-deletes", type=int, default=100, help="Abort if more than this many deletions are pending (default 100)")
    p.add_argument("--log-file", default=f"sso_cleanup_{datetime.now():%Y%m%d_%H%M%S}.log")
    p.add_argument("--report", default=None, help="CSV report path (default: alongside log file)")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    if args.execute and args.dry_run:
        p.error("--execute and --dry-run are mutually exclusive")
    return args


def main() -> int:
    args = parse_args()
    setup_logging(args.log_file, args.verbose)
    dry_run = not args.execute
    report_path = args.report or os.path.splitext(args.log_file)[0] + ".csv"

    log.info("=== SSO orphaned group cleanup | mode=%s | prefix=%r ===", "DRY-RUN" if dry_run else "EXECUTE", args.prefix)

    token = os.environ.get("OKTA_API_TOKEN")
    if not args.okta_url or not token:
        log.error("OKTA_ORG_URL (or --okta-url) and OKTA_API_TOKEN must be set")
        return 2

    try:
        aws = AwsSso(args.profile, args.region, args.identity_store_id)
        okta = OktaClient(args.okta_url, token)
        aws_groups = aws.groups_with_prefix(args.prefix)
        okta_names = okta.group_names_with_prefix(args.okta_prefix or args.prefix)
    except Exception:
        log.exception("Fatal error during initial discovery; nothing was changed")
        return 2

    if not aws_groups:
        log.info("No AWS groups match the prefix; nothing to do")
        return 0
    # Safety: an empty Okta result almost certainly means a bad token/URL/prefix,
    # not that every group was deleted.
    if not okta_names:
        log.error("Okta returned ZERO groups for the prefix. Refusing to continue (would mark every group orphaned).")
        return 2

    results = []  # rows for CSV
    counts = {"in_okta": 0, "has_assignments": 0, "would_delete": 0, "deleted": 0, "errors": 0}
    candidates = []

    # Pass 1: classify
    for g in aws_groups:
        gid, name = g["GroupId"], g["DisplayName"]
        try:
            if name.casefold() in okta_names:
                log.debug("KEEP  %s (%s): exists in Okta", name, gid)
                counts["in_okta"] += 1
                results.append((name, gid, "keep", "exists in Okta"))
                continue

            has, detail = aws.has_assignments(gid)
            if has:
                log.warning("KEEP  %s (%s): missing in Okta but has %s", name, gid, detail)
                counts["has_assignments"] += 1
                results.append((name, gid, "keep", f"missing in Okta; {detail}"))
            else:
                log.info("ORPHAN %s (%s): missing in Okta and %s", name, gid, detail)
                candidates.append(g)
        except (ClientError, BotoCoreError, requests.RequestException) as exc:
            counts["errors"] += 1
            log.exception("ERROR checking %s (%s); SKIPPING (not deleted): %s", name, gid, exc)
            results.append((name, gid, "error", f"check failed: {exc}"))
        except Exception as exc:
            counts["errors"] += 1
            log.exception("UNEXPECTED error checking %s (%s); SKIPPING: %s", name, gid, exc)
            results.append((name, gid, "error", f"unexpected: {exc}"))

    log.info("%d orphaned, assignment-free group(s) identified", len(candidates))
    if len(candidates) > args.max_deletes:
        log.error("%d candidates exceeds --max-deletes=%d. Aborting without changes; raise the limit if this is expected.",
                  len(candidates), args.max_deletes)
        write_report(report_path, results + [(g["DisplayName"], g["GroupId"], "aborted", "exceeds max-deletes") for g in candidates])
        return 3

    # Pass 2: delete
    for g in candidates:
        gid, name = g["GroupId"], g["DisplayName"]
        if dry_run:
            log.info("[DRY-RUN] would delete %s (%s)", name, gid)
            counts["would_delete"] += 1
            results.append((name, gid, "would_delete", "dry-run"))
            continue
        try:
            aws.delete_group(gid)
            log.info("DELETED %s (%s)", name, gid)
            counts["deleted"] += 1
            results.append((name, gid, "deleted", ""))
        except (ClientError, BotoCoreError) as exc:
            counts["errors"] += 1
            log.exception("ERROR deleting %s (%s): %s", name, gid, exc)
            results.append((name, gid, "error", f"delete failed: {exc}"))

    write_report(report_path, results)
    log.info("=== Summary: %s ===", counts)
    log.info("Log: %s | Report: %s", args.log_file, report_path)
    return 1 if counts["errors"] else 0


def write_report(path: str, rows) -> None:
    try:
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["group_name", "group_id", "action", "detail"])
            w.writerows(rows)
    except OSError:
        log.exception("Could not write report %s", path)


if __name__ == "__main__":
    sys.exit(main())