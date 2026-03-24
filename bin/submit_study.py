#!/usr/bin/env python3
"""Submit studies to ENA via the Webin drop-box XML submission service.

Read a study metadata file (JSON, CSV, or TSV), construct an
XML submission document, and submit new studies to ENA.

# TODO: Currently script supports multiple input format that might be unnecessary.
# TODO: Consider standardising on a single format (e.g. JSON and/or TSV) and deprecating the others.
# TODO: Consider which columns are mandatory vs optional. "alias" is optional, might be worth making it mandatory.
# TODO: Add input file validation and error handling (e.g. missing mandatory fields, long alias).
Input formats accepted (``--input``):

* ``.json``
* ``.csv``
* ``.tsv``

Example JSON inputs accepted::

        {
            "alias": "study-gut-2026",
            "STUDY_TITLE": "Gut microbiome study",
            "STUDY_ABSTRACT": "Characterisation of gut microbial communities",
            "existing_study_type": "Metagenomics"
        }

        [
            {
                "alias": "study-gut-2026",
                "STUDY_TITLE": "Gut microbiome study",
                "STUDY_ABSTRACT": "Characterisation of gut microbial communities",
                "existing_study_type": "Metagenomics"
            },
            ...
        ]

        {
            "studies": [
                {
                    "alias": "study-soil-2026",
                    "STUDY_TITLE": "Soil microbiome study",
                    "existing_study_type": "Other",
                    "new_study_type": "Environmental microbiome"
                }
            ]
        }

        {
            "data": [
                {
                    "alias": "study-soil-2026",
                    "STUDY_TITLE": "Soil microbiome study",
                }
            ]
        }

        {
            "Container": {
                "Studies": [
                    {
                        "STUDY_TITLE": "Marine metagenome study",
                        "STUDY_ABSTRACT": "Shotgun metagenomics from seawater"
                    }
                ]
            }
        }

Example CSV input accepted::

        alias,STUDY_TITLE,STUDY_ABSTRACT,existing_study_type
        study-gut-2026,Gut microbiome study,Characterisation of gut microbial communities,Metagenomics

Example TSV input accepted::

        alias\tSTUDY_TITLE\tSTUDY_ABSTRACT\texisting_study_type
        study-soil-2026\tSoil microbiome study\tSurvey of soil microbiota\tMetagenomics

Study metadata fields:

Mandatory:

* ``STUDY_TITLE`` — study title used in ``<TITLE>``.

Optional:

* ``alias`` — project alias; if missing, derived from ``STUDY_TITLE`` (first 50 characters).
* ``CENTER_PROJECT_NAME`` — written to ``<NAME>``; defaults to alias.
* ``STUDY_ABSTRACT`` or ``STUDY_DESCRIPTION`` — written to ``<DESCRIPTION>``.
* ``existing_study_type`` — included as PROJECT_ATTRIBUTE.
* ``new_study_type`` — included only when ``existing_study_type == "Other"``.

Credentials are read from environment variables to avoid
secrets appearing in shell history or process listings::

    export ENA_WEBIN=Webin-XXXXX
    export ENA_WEBIN_PASSWORD=XXXXX

Usage::

    # Submission to TEST server (submissions are discarded daily):
    python bin/submit_study.py \\
        --input studies.json \\
        --test

    # With hold date (max 2 years):
    python bin/submit_study.py \\
        --input studies.json \\
        --hold-until 2028-01-01

    # Log to file:
    python bin/submit_study.py \\
        --input studies.json \\
        --test --log submission.log
"""

from __future__ import annotations

import csv
import datetime
import hashlib
import json
import logging
import os
import sys
import xml.etree.ElementTree as ET
from collections.abc import Sequence
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

PROD_URL: Final = "https://www.ebi.ac.uk/ena/submit/drop-box"
TEST_URL: Final = "https://wwwdev.ebi.ac.uk/ena/submit/drop-box"


def submit_xml(
    base_url: str,
    auth: HTTPBasicAuth,
    submission_xml_bytes: bytes,
    project_xml_bytes: bytes,
) -> ET.Element:
    """Submit study XMLs to ENA via the submit/drop-box endpoint.

    Args:
        base_url: ENA submission service base URL.
        auth: HTTP basic-auth credentials.
        submission_xml_bytes: Serialised ``<SUBMISSION>`` XML.
        project_xml_bytes: Serialised ``<PROJECT_SET>`` XML.

    Returns:
        Parsed receipt XML element tree root.
    """
    url = f"{base_url}/submit"
    files = {
        "SUBMISSION": ("submission.xml", submission_xml_bytes, "application/xml"),
        "PROJECT": ("project.xml", project_xml_bytes, "application/xml"),
    }
    resp = requests.post(
        url, files=files, auth=auth, timeout=120,
    )
    resp.raise_for_status()
    return ET.fromstring(resp.content)


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
# File loading (JSON, CSV, TSV)
# -----------------------------------------------------------


def _is_metadata_row(row: Sequence[object]) -> bool:
    """Check whether *row* is a non-data header/metadata row.

    Such rows have at most one non-empty cell and are skipped
    during record extraction.
    """
    non_empty = sum(
        1 for c in row
        if c is not None and str(c).strip()
    )
    return non_empty <= 1


def extract_records_from_tabular(
    filepath: str | Path,
    delimiter: str = ",",
) -> list[dict[str, str]]:
    """Extract record dicts from a CSV or TSV file.

    Skip an optional leading metadata/label row if detected
    (a row with at most one non-empty cell).

    Args:
        filepath: Path to the tabular file.
        delimiter: Column delimiter character.

    Returns:
        List of record dicts.
    """
    with open(filepath, newline="", encoding="utf-8") as fh:
        rows = list(csv.reader(fh, delimiter=delimiter))

    if not rows:
        return []

    idx = 0
    if _is_metadata_row(rows[idx]):
        idx += 1
    if idx >= len(rows):
        return []

    headers = rows[idx]
    idx += 1

    records: list[dict[str, str]] = []
    for row in rows[idx:]:
        record: dict[str, str] = {}
        for col, val in zip(headers, row):
            col = col.strip()
            if col and val is not None and val.strip():
                record[col] = val.strip()
        if record:
            records.append(record)

    return records


def extract_records_from_json(
    input_data: object,
    record_keys: Sequence[str] = ("data",),
) -> list[dict[str, Any]] | None:
    """Extract record dicts from a JSON input.

    Handle several JSON shapes:

    * Container format (e.g. DataHarmonizer exports)::

        {"Container": {"<ClassName>s": [{...}, ...]}}

    * Plain list of dicts.
    * Dict with an entity-specific key or ``data`` key.
    * Single record object (no wrapper).

    Args:
        input_data: Parsed JSON data (any shape).
        record_keys: Dict keys to check for record lists
            (e.g. ``["studies", "data"]``).

    Returns:
        List of record dicts, or ``None`` if unrecognised.
    """
    if isinstance(input_data, list):
        return input_data

    if isinstance(input_data, dict):
        container = input_data.get("Container")
        if isinstance(container, dict):
            for key, val in container.items():
                if isinstance(val, list):
                    logger.info("Extracted records from Container.%s", key)
                    return val

        for key in record_keys:
            if key in input_data:
                return input_data[key]

        return [input_data]

    return None


def load_input_file(
    filepath: str | Path,
    json_record_keys: Sequence[str] = ("data",),
) -> list[dict[str, Any]] | None:
    """Load records from a supported file format.

    Supported formats: JSON, CSV, TSV.

    Args:
        filepath: Path to the input file.
        json_record_keys: Dict keys to check when parsing
            JSON (e.g. ``["studies", "data"]``).

    Returns:
        List of record dicts, or ``None`` if the format is
        unrecognised.
    """
    ext = Path(filepath).suffix.lower()
    if ext == ".json":
        with open(filepath) as fh:
            input_data = json.load(fh)
        return extract_records_from_json(
            input_data, json_record_keys,
        )
    if ext == ".csv":
        return extract_records_from_tabular(
            filepath, delimiter=",",
        )
    if ext == ".tsv":
        return extract_records_from_tabular(
            filepath, delimiter="\t",
        )
    return None


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


def build_submission_actions_xml(
    hold_until: str | None = None,
    action: str = "ADD",
) -> ET.Element:
    """Build the ``<SUBMISSION>`` actions XML element.

    This is submitted as the ``SUBMISSION`` multipart field.

    Args:
        hold_until: Optional hold-until date string
            (``YYYY-MM-DD``).
        action: Submission action — ``"ADD"`` for new studies
            or ``"MODIFY"`` to update existing ones.

    Returns:
        Root ``<SUBMISSION>`` element.
    """
    submission = ET.Element("SUBMISSION")
    actions = ET.SubElement(submission, "ACTIONS")
    main_action = ET.SubElement(actions, "ACTION")
    ET.SubElement(main_action, action.upper())
    if hold_until:
        hold_action = ET.SubElement(actions, "ACTION")
        hold_el = ET.SubElement(hold_action, "HOLD")
        hold_el.set("HoldUntilDate", hold_until)
    return submission


def build_project_set_xml(
    studies: list[dict[str, Any]],
    test: bool = False,
) -> ET.Element:
    """Build the ``<PROJECT_SET>`` XML element.

    This is submitted as the ``PROJECT`` multipart field.

    Args:
        studies: Study metadata dicts.
        test: If ``True``, append a timestamp-based hash to aliases
            for uniqueness in test submissions.

    Returns:
        Root ``<PROJECT_SET>`` element.
    """
    project_set = ET.Element("PROJECT_SET")
    for study in studies:
        alias = study.get(
            "alias",
            study.get("STUDY_TITLE", "").replace(" ", "_")[:50],
        )
        if test:
            # Append 8-character hash of current timestamp for uniqueness in test mode
            timestamp_hash = hashlib.md5(
                datetime.datetime.now().isoformat().encode()
            ).hexdigest()[:8]
            alias = f"{alias}_{timestamp_hash}"

        project = ET.SubElement(project_set, "PROJECT")
        project.set("alias", alias)

        name_text = study.get("CENTER_PROJECT_NAME", alias)
        if name_text:
            name_el = ET.SubElement(project, "NAME")
            name_el.text = name_text

        title_el = ET.SubElement(project, "TITLE")
        title_el.text = study.get("STUDY_TITLE", "")

        desc_text = (
            study.get("STUDY_ABSTRACT")
            or study.get("STUDY_DESCRIPTION", "")
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
    return project_set


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
    submission_xml_bytes: bytes,
    project_xml_bytes: bytes,
    action: str,
    results: dict[str, list[dict[str, Any]]],
    env_label: str,
    dry_run: bool,
) -> bool:
    """Validate, optionally submit, and parse one batch.

    Args:
        base_url: ENA submission base URL.
        auth: HTTP basic-auth credentials.
        submission_xml_bytes: Serialised ``<SUBMISSION>`` actions XML.
        project_xml_bytes: Serialised ``<PROJECT_SET>`` XML.
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
        logger.info("SUBMISSION XML:\n%s", submission_xml_bytes.decode("utf-8"))
        logger.info("PROJECT XML:\n%s", project_xml_bytes.decode("utf-8"))
        return True

    logger.info("Submitting %s to ENA (%s)...", action, env_label)
    try:
        receipt_root = submit_xml(base_url, auth, submission_xml_bytes, project_xml_bytes)
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

_JSON_RECORD_KEYS: Final = ("studies", "data")


@click.command(
    help="Register studies with ENA using Webin XML submission service.",
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
    """Register studies with ENA using Webin XML submission service."""
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
    studies = load_input_file(
        input_file, json_record_keys=_JSON_RECORD_KEYS,
    )
    if studies is None:
        logger.error("Unsupported file format. Supported: .json, .csv, .tsv")
        sys.exit(1)

    logger.info("Loaded %d study/studies from input", len(studies))

    if not studies:
        logger.info("No studies to submit")
        write_results({"submitted": [], "failed": []}, output)
        return

    results: dict[str, list[dict[str, Any]]] = {
        "submitted": [],
        "failed": [],
    }

    # -- Step 2: Build and submit XML --------------------
    logger.info("Building ADD XML for %d study/studies...", len(studies))
    submission_root = build_submission_actions_xml(hold_until=hold_until, action="ADD")
    project_root = build_project_set_xml(studies, test=use_test)
    submission_xml_bytes = xml_to_bytes(submission_root)
    project_xml_bytes = xml_to_bytes(project_root)
    logger.info("SUBMISSION XML document size: %d bytes", len(submission_xml_bytes))
    logger.debug("SUBMISSION XML:\n%s", submission_xml_bytes.decode("utf-8"))
    logger.info("PROJECT XML document size: %d bytes", len(project_xml_bytes))
    logger.debug("PROJECT XML:\n%s", project_xml_bytes.decode("utf-8"))
    ok = _do_submission(
        base_url, auth, submission_xml_bytes, project_xml_bytes,
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
    logger.info("SUBMISSION SUMMARY")
    logger.info("  Submitted (ADD): %d", len(results["submitted"]))
    for submission in results["submitted"]:
        alias = submission["alias"]
        accession = submission["accession"]
        external_accession = submission["external_accession"]
        logger.info(f"    {alias} -> {accession} ({external_accession})")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()  # type: ignore[call-arg]
