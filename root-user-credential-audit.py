import boto3
import csv
import base64
import time
from botocore.exceptions import ClientError

ROLE_NAME = "OrganizationAccountAccessRole"
OUTPUT_FILE = "root_credential_audit.csv"


def get_all_accounts():
    org = boto3.client("organizations")
    accounts = []
    paginator = org.get_paginator("list_accounts")

    for page in paginator.paginate():
        for acct in page["Accounts"]:
            if acct["Status"] == "ACTIVE":
                accounts.append({
                    "Id": acct["Id"],
                    "Name": acct["Name"]
                })
    return accounts


def assume_role(account_id):
    sts = boto3.client("sts")
    role_arn = f"arn:aws:iam::{account_id}:role/{ROLE_NAME}"

    try:
        response = sts.assume_role(
            RoleArn=role_arn,
            RoleSessionName="RootAuditSession"
        )
        creds = response["Credentials"]

        return boto3.client(
            "iam",
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
        )
    except ClientError as e:
        print(f"[ERROR] Cannot assume role in {account_id}: {e}")
        return None


def get_credential_report(iam_client):
    try:
        # Poll generate_credential_report() until State is COMPLETE
        for _ in range(10):
            response = iam_client.generate_credential_report()
            if response["State"] == "COMPLETE":
                break
            time.sleep(2)
        else:
            print("[ERROR] Credential report generation timed out.")
            return None

        # Fetch the completed report
        report_response = iam_client.get_credential_report()
        content = report_response["Content"]
        # Content may be a StreamingBody; read it if so
        if hasattr(content, "read"):
            content = content.read()
        return content.decode("utf-8") if isinstance(content, bytes) else content

    except ClientError as e:
        print(f"[ERROR] Credential report error: {e}")
    return None


def parse_root_user(report_csv):
    lines = report_csv.splitlines()
    headers = lines[0].split(",")

    for line in lines[1:]:
        cols = line.split(",")
        row = dict(zip(headers, cols))

        if row["user"] == "<root_account>":
            return {
                "password_enabled": row["password_enabled"],
                "mfa_active": row["mfa_active"],
                "access_key_1_active": row["access_key_1_active"],
                "access_key_2_active": row["access_key_2_active"]
            }
    return None


def main():
    accounts = get_all_accounts()

    with open(OUTPUT_FILE, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "AccountId",
            "AccountName",
            "PasswordEnabled",
            "MFAEnabled",
            "AccessKey1Active",
            "AccessKey2Active"
        ])

        for acct in accounts:
            print(f"Processing {acct['Id']} ({acct['Name']})")

            iam_client = assume_role(acct["Id"])
            if not iam_client:
                continue

            report = get_credential_report(iam_client)
            if not report:
                continue

            root_data = parse_root_user(report)
            if not root_data:
                continue

            writer.writerow([
                acct["Id"],
                acct["Name"],
                root_data["password_enabled"],
                root_data["mfa_active"],
                root_data["access_key_1_active"],
                root_data["access_key_2_active"]
            ])

    print(f"\nReport written to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()