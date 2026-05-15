#!/usr/bin/env python3
from __future__ import annotations

import csv
import datetime
import hashlib
import json
import logging
import os
import sys
import xml.etree.ElementTree as ET
from io import BytesIO
from pathlib import Path
from typing import Any, Final

import click
import requests
from requests.auth import HTTPBasicAuth


# -----------------------------------------------------------
# Logging
# -----------------------------------------------------------

logging.basicConfig(
    format="%(levelname)s: %(message)s",
    level=logging.INFO,
    stream=sys.stderr,
)
logger = logging.getLogger()


# -----------------------------------------------------------
# Credentials
# -----------------------------------------------------------


def get_credentials() -> tuple[str, str]:
    """Read ENA credentials from environment variables.

    Returns:
        Tuple of (*username*, *password*).

    Raises:
        SystemExit: If either variable is unset or empty.
    """
    username = os.environ.get("ENA_WEBIN", "").strip()
    password = os.environ.get("ENA_WEBIN_PASSWORD", "").strip()
    if not username or not password:
        logger.error("ENA_WEBIN and ENA_WEBIN_PASSWORD environment variables must be set")
        sys.exit(1)
    return username, password


# -----------------------------------------------------------
# ENA API helpers
# -----------------------------------------------------------

PROD_URL: Final = "https://www.ebi.ac.uk/ena/submit/webin-v2"
TEST_URL: Final = "https://wwwdev.ebi.ac.uk/ena/submit/webin-v2"


def submit_xml(
    base_url: str,
    auth: HTTPBasicAuth,
    xml_bytes: bytes,
) -> ET.Element:
    """Submit an XML document to ENA via Webin REST API v2.

    Args:
        base_url: ENA submission service base URL.
        auth: HTTP basic-auth credentials.
        xml_bytes: Serialised XML submission document.

    Returns:
        Parsed receipt XML element tree root.
    """
    url = f"{base_url}/submit"
    headers = {
        "Content-Type": "application/xml",
        "Accept": "application/xml",
    }
    try:
        resp = requests.post(
            url, data=xml_bytes,
            headers=headers, auth=auth, timeout=120,
        )
        resp.raise_for_status()
    except requests.exceptions.RequestException as e:
        logger.error(f"Network error: Could not reach ENA server. Details: {e}")
        sys.exit(1)
    
    try:
        return ET.fromstring(resp.content)
    except ET.ParseError:
        logger.error("The ENA server returned an invalid response (not XML).")
        sys.exit(1)


# -----------------------------------------------------------
# XML utilities
# -----------------------------------------------------------


def xml_to_bytes(root: ET.Element) -> bytes:
    """Serialise an ElementTree element to UTF-8 bytes."""
    tree = ET.ElementTree(root)
    buf = BytesIO()
    tree.write(buf, encoding="UTF-8", xml_declaration=True)
    return buf.getvalue()


# -----------------------------------------------------------
# Hold-until date validation
# -----------------------------------------------------------

_MAX_HOLD_YEARS: Final = 2


def validate_hold_until(hold_until: str) -> datetime.date:
    """Parse and validate a hold-until date string.

    Args:
        hold_until: Date string in ``YYYY-MM-DD`` format.

    Returns:
        Parsed date.

    Raises:
        click.BadParameter: If the date format is invalid,
            in the past, or more than 2 years from today.
    """
    try:
        hold_date = datetime.date.fromisoformat(hold_until)
    except ValueError:
        raise click.BadParameter(
            f"Invalid date format: {hold_until!r}. Expected YYYY-MM-DD."
        ) from None

    today = datetime.date.today()
    max_date = today.replace(year=today.year + _MAX_HOLD_YEARS)

    if hold_date > max_date:
        raise click.BadParameter(
            f"Hold date {hold_until} is more than {_MAX_HOLD_YEARS} years from today"
            f" ({today}). Maximum allowed: {max_date}."
        )

    if hold_date <= today:
        raise click.BadParameter(
            f"Hold date {hold_until} is not in the future (today is {today})."
        )

    return hold_date


# -----------------------------------------------------------
# Study metadata field definitions
# -----------------------------------------------------------

#: Fields that must be present and non-empty in every record.
_REQUIRED_FIELDS: Final[frozenset[str]] = frozenset({
    "alias",
    "study_title",
})

#: Fields that are recognised but optional.
_OPTIONAL_FIELDS: Final[frozenset[str]] = frozenset({
    "project_name",
    "study_abstract",
    "study_description",
    "existing_study_type",
    "new_study_type",
})

#: All recognised field names (required + optional).
_ALL_FIELDS: Final[frozenset[str]] = _REQUIRED_FIELDS | _OPTIONAL_FIELDS


# -----------------------------------------------------------
# File loading (JSON, CSV, TSV)
# -----------------------------------------------------------


def extract_records_from_tabular(
    filepath: str | Path,
    delimiter: str = ",",
) -> list[dict[str, str]]:
    """Extract record dicts from a CSV or TSV file.

    Only columns present in _ALL_FIELDS are retained;
    unknown columns are ignored.

    Args:
        filepath: Path to the tabular file.
        delimiter: Column delimiter character.

    Returns:
        List of record dicts.
    """
    records = []

    with open(filepath, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh, delimiter=delimiter)
        for line in reader:
            record = {}
            for col in _ALL_FIELDS:
                value = line.get(col, "").strip()
                if value:
                    record[col] = value
            if record:
                records.append(record)

        return records


def extract_records_from_json(
    filepath: str | Path,
) -> list[dict[str, Any]]:
    """Extract record dicts from a JSON file.

    Handle two JSON shapes:

    * Plain list of dicts.
    * Single record object (no wrapper).

    Args:
        filepath: Path to the JSON file.

    Returns:
        List of record dicts, or [] if unrecognised.
    """
    with open(filepath) as fh:
        input_data = json.load(fh)

    if isinstance(input_data, list):
        return input_data

    if isinstance(input_data, dict):
        return [input_data]

    return []


def load_and_validate_input_file(
    filepath: str | Path,
) -> list[dict[str, Any]]:
    """Load and validate records from a supported file format.

    Supported formats: JSON, CSV, TSV. Other formats will cause a ValueError.
    Records are validated against _REQUIRED_FIELDS before being returned;
    missing required fields will cause a ValueError.

    Args:
        filepath: Path to the input file.

    Returns:
        List of record dicts. If the file format is
        unrecognised (based on file extension) or required fields are missing,
        raises ValueError.
    """
    ext = Path(filepath).suffix.lower()

    if ext in [".csv", ".tsv"]:
        delimiter = "," if ext == ".csv" else "\t"
        with open(filepath, "r", encoding="utf-8") as f:
            header_line = f.readline()
            if not header_line:
                raise ValueError(f"File {filepath} is empty.")
            
            # Clean up headers (strip quotes and whitespace)
            headers = [h.strip().replace('"', '') for h in header_line.split(delimiter)]
            missing = [f for f in _REQUIRED_FIELDS if f not in headers]
            
            if missing:
                # Use the logger you set up earlier!
                logger.error(f"Missing required columns in {ext} file: {', '.join(missing)}")
                raise ValueError(f"Missing columns: {', '.join(missing)}")
    # --------------------------------------------------------

    if ext == ".json":
        records = extract_records_from_json(filepath)
    elif ext == ".csv":
        records = extract_records_from_tabular(filepath, delimiter=",")
    elif ext == ".tsv":
        records = extract_records_from_tabular(filepath, delimiter="\t")
    else:
        raise ValueError(f"Unsupported file format: {ext}. Supported: .json, .csv, .tsv")

    if not records:
        raise ValueError(f"File {filepath} seems to be empty. Check the format and content.")

    for record in records:
        for field in _REQUIRED_FIELDS:
            if not record.get(field, "").strip():
                raise ValueError(
                    f"Record with alias {record.get('alias', '<missing>')} is missing required field: {field}"
                )

    return records


# -----------------------------------------------------------
# Result output
# -----------------------------------------------------------


def write_results(
    results: dict[str, list[dict[str, Any]]],
    output_path: Path | None,
) -> None:
    """Write JSON results to file or stdout."""
    json_str = json.dumps(results, indent=2)
    if output_path:
        with open(output_path, "w") as fh:
            fh.write(json_str + "\n")
        logger.info("Results written to %s", output_path)
    else:
        print(json_str)


# -----------------------------------------------------------
# XML construction
# -----------------------------------------------------------


def build_submission_xml(
    studies: list[dict[str, Any]],
    hold_until: str | None = None,
    action: str = "ADD",
    test: bool = False,
) -> ET.Element:
    """Build a ``<WEBIN>`` XML document for submitting studies.

    Args:
        studies: Study metadata dicts.
        hold_until: Optional hold-until date string
            (``YYYY-MM-DD``).
        action: Submission action — ``"ADD"`` for new studies
            or ``"MODIFY"`` to update existing ones.
        test: If ``True``, append a timestamp-based hash to aliases
            for uniqueness in test submissions.

    Returns:
        Root ``<WEBIN>`` element.
    """
    webin = ET.Element("WEBIN")

    # SUBMISSION_SET
    submission_set = ET.SubElement(webin, "SUBMISSION_SET")
    submission = ET.SubElement(submission_set, "SUBMISSION")
    sub_alias = f"study-submission-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    submission.set("alias", sub_alias)
    actions = ET.SubElement(submission, "ACTIONS")
    main_action = ET.SubElement(actions, "ACTION")
    ET.SubElement(main_action, action.upper())
    if hold_until:
        hold_action = ET.SubElement(actions, "ACTION")
        hold_el = ET.SubElement(hold_action, "HOLD")
        hold_el.set("HoldUntilDate", hold_until)

    # PROJECT_SET
    project_set = ET.SubElement(webin, "PROJECT_SET")
    for study in studies:
        _add_project_element(project_set, study, test=test)
    return webin


def _add_project_element(
    project_set: ET.Element,
    study: dict[str, Any],
    test: bool = False,
) -> None:
    """Append a ``<PROJECT>`` element to *project_set*."""
    alias = study.get("alias", "")
    if test:
        # Append 8-character hash of current timestamp for uniqueness in test mode
        timestamp_hash = hashlib.md5(
            datetime.datetime.now().isoformat().encode()
        ).hexdigest()[:8]
        alias = f"{alias}_{timestamp_hash}"

    project = ET.SubElement(project_set, "PROJECT")
    project.set("alias", alias)

    name_text = study.get("project_name", study.get("study_title", ""))
    if name_text:
        name_el = ET.SubElement(project, "NAME")
        name_el.text = name_text

    title_el = ET.SubElement(project, "TITLE")
    title_el.text = study.get("study_title", "")

    desc_text = (
        study.get("study_abstract")
        or study.get("study_description", "")
    )
    if desc_text:
        desc_el = ET.SubElement(project, "DESCRIPTION")
        desc_el.text = desc_text

    sp = ET.SubElement(project, "SUBMISSION_PROJECT")
    ET.SubElement(sp, "SEQUENCING_PROJECT")
    # TODO: Check existing_study_type and new_study_type metadata fields, do we need those?
    study_type = study.get("existing_study_type")
    if study_type:
        attrs = ET.SubElement(
            project, "PROJECT_ATTRIBUTES",
        )
        _add_project_attribute(
            attrs, "existing_study_type", study_type,
        )
        new_type = study.get("new_study_type")
        if new_type and study_type == "Other":
            _add_project_attribute(
                attrs, "new_study_type", new_type,
            )


def _add_project_attribute(
    parent: ET.Element,
    tag_text: str,
    value_text: str,
) -> None:
    """Append a ``<PROJECT_ATTRIBUTE>`` to *parent*."""
    attr = ET.SubElement(parent, "PROJECT_ATTRIBUTE")
    tag_el = ET.SubElement(attr, "TAG")
    tag_el.text = tag_text
    val_el = ET.SubElement(attr, "VALUE")
    val_el.text = value_text


# -----------------------------------------------------------
# Receipt parsing
# -----------------------------------------------------------


def parse_xml_receipt(
    receipt_root: ET.Element,
) -> tuple[bool, list[dict[str, str]], list[str]]:
    """Parse an ENA XML receipt for study submissions.

    Args:
        receipt_root: Root element of the receipt XML.

    Returns:
        Tuple of (*success*, *accessions*, *messages*).
    """
    success = receipt_root.get("success", "false").lower() == "true"
    accessions: list[dict[str, str]] = []
    messages: list[str] = []

    msgs_el = receipt_root.find("MESSAGES")
    if msgs_el is not None:
        for info in msgs_el.findall("INFO"):
            messages.append(f"INFO: {info.text}")
        for err in msgs_el.findall("ERROR"):
            messages.append(f"ERROR: {err.text}")

    # TODO: "accession" should be present for successful submissions
    # TODO: remove get default and log error if missing.
    for proj in receipt_root.findall("PROJECT"):
        acc_info: dict[str, str] = {
            "alias": proj.get("alias", ""),
            "accession": proj.get("accession", ""),
            "status": proj.get("status", ""),
            "holdUntilDate": proj.get("holdUntilDate", ""),
        }
        ext = proj.find("EXT_ID")
        if ext is not None:
            acc_info["external_accession"] = ext.get("accession", "")
            acc_info["external_type"] = ext.get("type", "")
        accessions.append(acc_info)

    # Some receipts use STUDY instead of PROJECT.
    for study in receipt_root.findall("STUDY"):
        accessions.append({
            "alias": study.get("alias", ""),
            "accession": study.get("accession", ""),
            "status": study.get("status", ""),
        })

    return success, accessions, messages


# -----------------------------------------------------------
# Submission helper
# -----------------------------------------------------------


def _do_submission(
    base_url: str,
    auth: Any,
    xml_bytes: bytes,
    action: str,
    results: dict[str, list[dict[str, Any]]],
    env_label: str,
    dry_run: bool,
) -> bool:
    """Validate, optionally submit, and parse one batch.

    Args:
        base_url: ENA submission base URL.
        auth: HTTP basic-auth credentials.
        xml_bytes: Serialised XML submission document.
        action: Label for log messages (``"ADD"`` or
            ``"MODIFY"``).
        results: Results dict to accumulate into.
        env_label: ``"TEST server"`` or ``"LIVE server"``.
        dry_run: If ``True``, skip the actual submission.

    Returns:
        ``True`` if the batch succeeded (or dry run).
    """
    if dry_run:
        logger.info("DRY RUN — skipping %s submission", action)
        logger.info("Generated XML:\n%s", xml_bytes.decode("utf-8"))
        return True

    logger.info("Submitting %s to ENA (%s)...", action, env_label)
    try:
        receipt_root = submit_xml(base_url, auth, xml_bytes)
    except requests.exceptions.HTTPError as exc:
        logger.error("HTTP error during %s submission: %s", action, exc)
        if exc.response is not None:
            logger.error("Response body: %s", exc.response.text)
        return False

    success, accessions, receipt_messages = parse_xml_receipt(receipt_root)
    for msg in receipt_messages:
        logger.info("  Receipt: %s", msg)

    if success:
        logger.info("%s SUCCESSFUL", action)
        for acc in accessions:
            ext = acc.get("external_accession", "")
            ext_suffix = f" (study: {ext})" if ext else ""
            logger.info(
                "  %s: alias=%s accession=%s status=%s%s",
                action, acc["alias"], acc["accession"], acc["status"], ext_suffix,
            )
            results["submitted"].append(acc)
    else:
        logger.error("%s FAILED", action)
        receipt_xml_str = ET.tostring(
            receipt_root, encoding="unicode",
        )
        logger.error("Receipt XML: %s", receipt_xml_str)
        results["failed"].extend(accessions)

    return success


# -----------------------------------------------------------
# Main
# -----------------------------------------------------------

@click.command(
    help="Submit studies to ENA via the Webin REST API v2.",
)
@click.option(
    "--input", "input_file",
    required=True,
    type=click.Path(exists=True, path_type=Path),
    help="Path to study metadata file (JSON, CSV, or TSV)",
)
@click.option(
    "--test", "use_test",
    is_flag=True, default=False,
    help="Use the ENA test service (submissions are discarded daily)",
)
@click.option(
    "--hold-until",
    default=None,
    help="Hold studies private until this date (YYYY-MM-DD, max 2 years from now)",
)
@click.option(
    "--output",
    type=click.Path(path_type=Path),
    default=None,
    help="Path to write JSON accession results (default: stdout)",
)
@click.option(
    "--validate",
    is_flag=True, default=False,
    help="Validate and build XML but do not submit to ENA",
)
def main(
    input_file: Path,
    use_test: bool,
    hold_until: str | None,
    output: Path | None,
    validate: bool,
) -> None:
    """Submit studies to ENA via the Webin REST API v2."""
    username, password = get_credentials()

    env_label = "TEST server" if use_test else "LIVE server"
    logger.info("ENA Study Submission — environment: %s", env_label)
    base_url = TEST_URL if use_test else PROD_URL

    auth = HTTPBasicAuth(username, password)
    logger.debug("Auth username: %s", username)

    if hold_until:
        validate_hold_until(hold_until)

    # -- Step 1: Load input file -------------------------
    logger.info("Loading input: %s", input_file)
    try:
        studies = load_and_validate_input_file(input_file)
    except ValueError as exc:
        # Re-raise as click.BadParameter to get nice error formatting without a full stack trace
        raise click.BadParameter(str(exc), param_hint="--input") from exc

    logger.info("Loaded %d study/studies from input", len(studies))

    results: dict[str, list[dict[str, Any]]] = {
        "submitted": [],
        "failed": [],
    }

    # -- Step 2: Build and submit XML --------------------
    logger.info("Building ADD XML for %d study/studies...", len(studies))
    xml_root = build_submission_xml(
        studies,
        hold_until=hold_until,
        action="ADD",
        test=use_test,
    )
    xml_bytes = xml_to_bytes(xml_root)
    logger.info("XML document size: %d bytes", len(xml_bytes))
    logger.debug("Generated XML:\n%s", xml_bytes.decode("utf-8"))
    ok = _do_submission(
        base_url, auth, xml_bytes,
        action="ADD",
        results=results,
        env_label=env_label,
        dry_run=validate,
    )

    if not ok:
        sys.exit(1)

    # -- Step 3: Output results --------------------------
    write_results(results, output)

    logger.info("=" * 60)
    logger.info("SUBMISSION SUMMARY - COMPLETED SUCCESSFULLY")
    logger.info("Environment: %s", env_label)
    logger.info("Total Studies Processed: %d", len(studies))
    logger.info("  Submitted (ADD): %d", len(results["submitted"]))
    
    for submission in results["submitted"]:
        alias = submission.get("alias", "Unknown")
        accession = submission.get("accession", "Pending")
        # Using .get() here makes it robust against missing dictionary keys
        logger.info(f"    {alias} -> {accession}")
    
    logger.info("=" * 60)


if __name__ == "__main__":
    main()  # type: ignore[call-arg]
