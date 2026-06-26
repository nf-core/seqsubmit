from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import submit_study


def _receipt(success: bool, *, error: str | None = None, accession: str = "PRJEB1") -> ET.Element:
    root = ET.Element("RECEIPT", {"success": str(success).lower()})
    if success:
        ET.SubElement(root, "PROJECT", {"alias": "study", "accession": accession, "status": "PRIVATE"})
    if error:
        messages = ET.SubElement(root, "MESSAGES")
        ET.SubElement(messages, "ERROR").text = error
    return root


def test_get_duplicate_object_accession_extracts_accession():
    messages = [
        'ERROR: In submission, alias: "study-submission". The object being added already exists '
        'in the submission account with accession: "PRJEB12345".'
    ]

    assert submit_study.get_duplicate_object_accession(messages) == "PRJEB12345"


def test_duplicate_object_error_message_warns_for_submission_accession():
    message = submit_study.duplicate_object_error_message("ERA36583436")

    assert "submission accession" in message
    assert "--submission_study <study accession>" in message


def test_do_submission_cancels_duplicate_test_object_and_retries(monkeypatch):
    duplicate_error = (
        'In submission, alias: "study-submission". The object being added already exists '
        'in the submission account with accession: "PRJEB12345".'
    )
    receipts = [
        _receipt(False, error=duplicate_error),
        _receipt(True, accession="PRJEB67890"),
    ]
    cancelled = []

    def fake_submit_xml(base_url, auth, xml_bytes):
        return receipts.pop(0)

    def fake_cancel_existing_object(base_url, auth, accession):
        cancelled.append(accession)
        return True

    monkeypatch.setattr(submit_study, "submit_xml", fake_submit_xml)
    monkeypatch.setattr(submit_study, "cancel_existing_object", fake_cancel_existing_object)

    results = {"submitted": [], "failed": []}
    ok = submit_study._do_submission(
        submit_study.TEST_URL,
        auth=None,
        xml_bytes=b"<WEBIN />",
        action="ADD",
        results=results,
        env_label="TEST server",
        dry_run=False,
        replace_existing_test_study=True,
    )

    assert ok
    assert cancelled == ["PRJEB12345"]
    assert results["submitted"][0]["accession"] == "PRJEB67890"
    assert results["failed"] == []
