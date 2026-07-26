#!/usr/bin/env python3

import argparse
import json
import os
import re
import tempfile


REQUIRED_ENVIRONMENT = (
    "FASTGRAM_BUNDLE_ID",
    "FASTGRAM_API_ID",
    "FASTGRAM_API_HASH",
    "FASTGRAM_TEAM_ID",
)


def environment_or_default(name, default):
    return os.environ.get(name) or default


def required_environment():
    missing = [name for name in REQUIRED_ENVIRONMENT if not os.environ.get(name)]
    if missing:
        raise SystemExit("Missing required environment variables: {}".format(", ".join(missing)))

    bundle_id = os.environ["FASTGRAM_BUNDLE_ID"]
    api_id = os.environ["FASTGRAM_API_ID"]
    api_hash = os.environ["FASTGRAM_API_HASH"]
    team_id = os.environ["FASTGRAM_TEAM_ID"]

    if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id):
        raise SystemExit("FASTGRAM_BUNDLE_ID is not a valid bundle identifier")
    if not api_id.isdigit():
        raise SystemExit("FASTGRAM_API_ID must contain only digits")
    if not re.fullmatch(r"[0-9a-fA-F]{32}", api_hash):
        raise SystemExit("FASTGRAM_API_HASH must be a 32-character hexadecimal value")
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise SystemExit("FASTGRAM_TEAM_ID must be a 10-character Apple Team ID")

    return {
        "bundle_id": bundle_id,
        "api_id": api_id,
        "api_hash": api_hash,
        "team_id": team_id,
        "app_center_id": environment_or_default("FASTGRAM_APP_CENTER_ID", "0"),
        "is_internal_build": environment_or_default("FASTGRAM_IS_INTERNAL_BUILD", "true"),
        "is_appstore_build": environment_or_default("FASTGRAM_IS_APPSTORE_BUILD", "false"),
        "appstore_id": environment_or_default("FASTGRAM_APPSTORE_ID", "0"),
        "app_specific_url_scheme": environment_or_default("FASTGRAM_URL_SCHEME", "fastgram"),
        "premium_iap_product_id": os.environ.get("FASTGRAM_PREMIUM_IAP_PRODUCT_ID") or "",
        "enable_siri": environment_or_default("FASTGRAM_ENABLE_SIRI", "true").lower() == "true",
        "enable_icloud": environment_or_default("FASTGRAM_ENABLE_ICLOUD", "false").lower() == "true",
        "enable_communication_notifications": environment_or_default(
            "FASTGRAM_ENABLE_COMMUNICATION_NOTIFICATIONS", "true"
        ).lower() == "true",
    }


def main():
    parser = argparse.ArgumentParser(description="Generate Fastgram's untracked build configuration.")
    parser.add_argument(
        "--output",
        default="build-system/fastgram-local-configuration.json",
        help="Destination JSON file",
    )
    args = parser.parse_args()

    configuration = required_environment()
    output_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    descriptor, temporary_path = tempfile.mkstemp(
        prefix=".fastgram-configuration-",
        dir=os.path.dirname(output_path),
        text=True,
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as file:
            json.dump(configuration, file, indent=2)
            file.write("\n")
        os.replace(temporary_path, output_path)
    finally:
        if os.path.exists(temporary_path):
            os.remove(temporary_path)

    print("Generated {}".format(output_path))


if __name__ == "__main__":
    main()
