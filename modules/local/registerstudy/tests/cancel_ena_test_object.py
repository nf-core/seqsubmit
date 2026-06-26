#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime
import os
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

TEST_SUBMIT_URL = "https://wwwdev.ebi.ac.uk/ena/submit/webin-v2/submit"


def build_cancel_xml(accession: str) -> bytes:
    """Build a Webin v2 CANCEL manifest for a private test object."""
    webin = ET.Element("WEBIN")
    submission_set = ET.SubElement(webin, "SUBMISSION_SET")
    submission = ET.SubElement(submission_set, "SUBMISSION")
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    submission.set("alias", f"cancel-{accession}-{timestamp}")
    actions = ET.SubElement(submission, "ACTIONS")
    action = ET.SubElement(actions, "ACTION")
    ET.SubElement(action, "CANCEL", {"target": accession})
    return ET.tostring(webin, encoding="UTF-8", xml_declaration=True)


def submit_cancel(accession: str, username: str, password: str) -> tuple[bool, str]:
    """Submit a CANCEL manifest and return success plus response text."""
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    request = urllib.request.Request(
        TEST_SUBMIT_URL,
        data=build_cancel_xml(accession),
        headers={
            "Authorization": f"Basic {token}",
            "Content-Type": "application/xml",
            "Accept": "application/xml",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return False, body

    try:
        receipt = ET.fromstring(body)
    except ET.ParseError:
        return False, body
    return receipt.get("success", "false").lower() == "true", body


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: cancel_ena_test_object.py <accession>", file=sys.stderr)
        return 2

    username = os.environ.get("ENA_WEBIN", "").strip()
    password = os.environ.get("ENA_WEBIN_PASSWORD", "").strip()
    if not username or not password:
        print("ENA_WEBIN and ENA_WEBIN_PASSWORD must be set", file=sys.stderr)
        return 2

    accession = sys.argv[1].strip()
    success, body = submit_cancel(accession, username, password)
    print(body)
    if not success:
        print(f"Failed to cancel ENA test object {accession}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
