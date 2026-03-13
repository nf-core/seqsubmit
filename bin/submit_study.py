#!/usr/bin/env python3
"""Submit raw-reads, assembly and genome studies to ENA via the Webin REST API v2.

Read a DataHarmonizer export containing study metadata,
check for duplicate studies already registered under the
Webin account, construct an XML submission document, and
submit new studies to ENA.

Credentials are read from environment variables to avoid
secrets appearing in shell history or process listings::

    export ENA_WEBIN=Webin-XXXXX
    export ENA_WEBIN_PASSWORD=SECRET

Usage::

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
import json
import logging
import os
import sys
import xml.etree.ElementTree as ET
from collections.abc import Callable, Sequence
from io import BytesIO
from pathlib import Path
from typing import Any, Final

import click
import requests
from requests.auth import HTTPBasicAuth


# -----------------------------------------------------------
# Logging
# -----------------------------------------------------------

# All loggers in the ENA submission scripts share this root,
# so configuring it once propagates to all child loggers.
_LOGGER_NAME: Final = "ena_submit"

logger = logging.getLogger("ena_submit.study")


def setup_logging(log_file: Path | None = None) -> None:
    """Configure stderr and optional file logging.

    Attach handlers to the ``ena_submit`` parent logger.
    Child loggers (e.g. ``ena_submit.study``) propagate
    their messages to these handlers automatically.

    Args:
        log_file: Path to a log file.  If provided,
            debug-level messages are written there in
            addition to stderr.
    """
    root = logging.getLogger(_LOGGER_NAME)

    # Avoid duplicate handlers on repeated calls.
    if root.handlers:
        return

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    root.setLevel(logging.DEBUG)

    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setLevel(logging.INFO)
    stderr_handler.setFormatter(fmt)
    root.addHandler(stderr_handler)

    if log_file:
        file_handler = logging.FileHandler(log_file)
        file_handler.setLevel(logging.DEBUG)
        file_handler.setFormatter(fmt)
        root.addHandler(file_handler)


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


def get_base_url(use_test: bool) -> str:
    """Return the ENA Webin v2 submission base URL."""
    return TEST_URL if use_test else PROD_URL


def submit_xml(
    base_url: str,
    auth: HTTPBasicAuth,
    xml_bytes: bytes,
) -> ET.Element:
    """Submit an XML document to ENA via Webin v2.

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
    resp = requests.post(
        url, data=xml_bytes,
        headers=headers, auth=auth, timeout=120,
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
# ENA checklist XML parsing
# -----------------------------------------------------------


def parse_checklist_units(
    xml_path: str | Path,
) -> dict[str, str]:
    """Parse an ENA checklist XML and return field units.

    Reads the ``<FIELD>`` elements from an ENA checklist XML
    file (e.g. ``ERC000015.xml``) and returns a mapping from
    slot name to unit string for every field that declares a
    ``<UNITS><UNIT>`` element.

    Args:
        xml_path: Path to the ENA checklist XML file.

    Returns:
        Dict mapping slot name to unit string.
        Fields without units are absent from the dict.
    """
    units: dict[str, str] = {}
    try:
        tree = ET.parse(str(xml_path))
    except ET.ParseError as exc:
        logger.warning(
            "Could not parse checklist XML %s: %s",
            xml_path, exc,
        )
        return units

    for field in tree.iter("FIELD"):
        name_el = field.find("NAME")
        if name_el is None or not name_el.text:
            continue
        units_el = field.find("UNITS")
        if units_el is None:
            continue
        unit_el = units_el.find("UNIT")
        if unit_el is None or not unit_el.text:
            continue
        units[name_el.text.strip()] = unit_el.text.strip()

    return units


# -----------------------------------------------------------
# XSD validation (structural fallback only)
# -----------------------------------------------------------


def validate_xml_against_xsd(
    xml_bytes: bytes,
    _fragment_tag: str | None = None,  # unused; kept for API compatibility
    fallback_checker: Callable[
        [bytes, list[str]], tuple[bool, list[str]]
    ] | None = None,
) -> tuple[bool, list[str]]:
    """Validate XML bytes using a structural check.

    Full XSD validation via lxml is not available in this
    container.  Uses *fallback_checker* if provided,
    otherwise checks that the document is well-formed XML.

    Args:
        xml_bytes: Serialised XML document.
        _fragment_tag: Unused; kept for API compatibility.
        fallback_checker: Optional function called with
            (*xml_bytes*, *messages*) that returns
            (*is_valid*, *messages*).

    Returns:
        Tuple of (*is_valid*, *messages*).
    """
    messages: list[str] = []

    if fallback_checker is not None:
        return fallback_checker(xml_bytes, messages)

    try:
        ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        messages.append(
            f"ERROR: XML is not well-formed: {exc}"
        )
        return False, messages

    messages.append(
        "XML is well-formed (basic check passed)"
    )
    return True, messages


# -----------------------------------------------------------
# File loading (JSON, CSV, TSV)
# -----------------------------------------------------------


def _is_metadata_row(row: Sequence[object]) -> bool:
    """Check whether *row* is a DataHarmonizer label row.

    These rows have at most one non-empty cell.
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

    Skip an optional DataHarmonizer metadata row if
    detected.

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
    """Extract record dicts from a DataHarmonizer JSON export.

    Handle several JSON shapes:

    * DataHarmonizer Container format::

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
# Reports API
# -----------------------------------------------------------


def fetch_from_reports_endpoint(
    url: str,
    auth: HTTPBasicAuth,
    max_results: int = 5000,
) -> list[dict[str, Any]] | None:
    """Fetch records from a single Webin Reports endpoint.

    Args:
        url: Full URL of the reports endpoint.
        auth: HTTP basic-auth credentials.
        max_results: Maximum number of results to request.

    Returns:
        List of raw report dicts, or ``None`` on error.
    """
    params = {
        "format": "json",
        "max-results": max_results,
    }

    req = requests.Request("GET", url, params=params, auth=auth)
    prepared = req.prepare()
    logger.debug('curl -u %s:*** "%s"', auth.username, prepared.url)

    try:
        resp = requests.get(url, params=params, auth=auth, timeout=60)
        logger.info("Reports API at %s returned %s", url, resp.status_code)
        resp.raise_for_status()
        return resp.json()

    except requests.exceptions.HTTPError as exc:
        status = (
            exc.response.status_code
            if exc.response is not None
            else "unknown"
        )
        if status == 404:
            logger.info("Reports API at %s returned 404 — no records yet", url)
            return []
        if status in (401, 403):
            logger.warning(
                "Reports API at %s returned %s — endpoint may not be available"
                " or credentials may differ",
                url, status,
            )
            return None
        logger.warning("Reports API at %s returned HTTP %s", url, status)
        return None

    except requests.exceptions.RequestException as exc:
        logger.warning("Reports API at %s failed: %s", url, exc)
        return None


def fetch_account_records(
    auth: HTTPBasicAuth,
    use_test: bool,
    prod_url: str,
    test_url: str,
    normalizer: Callable[
        [dict[str, Any]], dict[str, str] | None
    ],
    entity_label: str,
    max_results: int = 5000,
) -> list[dict[str, str]]:
    """Fetch and normalise records from the Reports API.

    Try test endpoint first (if *use_test*), then fall back
    to production.

    Args:
        auth: HTTP basic-auth credentials.
        use_test: Try the test endpoint first.
        prod_url: Production reports endpoint URL.
        test_url: Test reports endpoint URL.
        normalizer: Callable that maps a raw report dict to
            a normalised dict, or ``None`` to skip.
        entity_label: Label for log messages (e.g.
            ``"studies"``).
        max_results: Maximum number of results to request.

    Returns:
        List of normalised record dicts.
    """
    urls = (
        [test_url, prod_url] if use_test
        else [prod_url]
    )

    for url in urls:
        logger.info("Fetching account %s from: %s", entity_label, url)
        raw = fetch_from_reports_endpoint(url, auth, max_results)
        if raw is None:
            continue

        records: list[dict[str, str]] = []
        for entry in raw:
            report = entry.get("report")
            if report is None:
                continue
            normalized = normalizer(report)
            if normalized is not None:
                records.append(normalized)

        logger.info("Found %d %s in account", len(records), entity_label)
        return records

    logger.warning(
        "Could not reach any Webin reports endpoint."
        " Duplicate checking for %s will be skipped.",
        entity_label,
    )
    return []


# -----------------------------------------------------------
# Duplicate detection (alias + title matching)
# -----------------------------------------------------------


def find_duplicates_by_alias_title(
    new_records: Sequence[dict[str, Any]],
    account_records: Sequence[dict[str, str]],
    title_field: str,
    entity_label: str,
) -> dict[int, dict[str, str]]:
    """Check new records against account records.

    Match by ``alias`` (preferred) or by the entity-specific
    title field against the pre-fetched account records from
    the Webin Reports API.

    Args:
        new_records: Records the user wants to submit.
        account_records: Existing records already registered
            under the Webin account.
        title_field: Field name for the title in new records
            (e.g. ``"STUDY_TITLE"`` or ``"SAMPLE_TITLE"``).
        entity_label: Label for log messages.

    Returns:
        Mapping of index in *new_records* to matching
        existing record info.
    """
    duplicates: dict[int, dict[str, str]] = {}
    total = len(new_records)

    if not account_records:
        return duplicates

    by_title: dict[str, dict[str, str]] = {}
    by_alias: dict[str, dict[str, str]] = {}
    for rec in account_records:
        title = (rec.get("title") or "").strip()
        alias = (rec.get("alias") or "").strip()
        if title:
            by_title[title] = rec
        if alias:
            by_alias[alias] = rec

    logger.info(
        "Checking %d new %s against %d existing account %s...",
        total, entity_label, len(account_records), entity_label,
    )

    for i, record in enumerate(new_records):
        new_title = (
            record.get(title_field) or ""
        ).strip()
        new_alias = (record.get("alias") or "").strip()

        if not new_title and not new_alias:
            continue

        match = _match_by_alias_title(
            new_alias, new_title, by_alias, by_title,
        )
        if match is not None:
            duplicates[i] = match
            logger.info(
                "  Duplicate: '%s' matches %s -> %s (%s)",
                new_title or new_alias,
                match["match_reason"],
                match["accession"],
                match["status"],
            )

            if len(duplicates) == total:
                logger.info("All %s are duplicates — skipping further checks", entity_label)
                return duplicates

    return duplicates


def _match_by_alias_title(
    new_alias: str,
    new_title: str,
    by_alias: dict[str, dict[str, str]],
    by_title: dict[str, dict[str, str]],
) -> dict[str, str] | None:
    """Return matching record info or ``None``."""
    if new_alias and new_alias in by_alias:
        rec = by_alias[new_alias]
        reason = f"alias '{new_alias}'"
    elif new_title and new_title in by_title:
        rec = by_title[new_title]
        reason = f"title '{new_title}'"
    else:
        return None

    return {
        "accession": rec.get("accession", ""),
        "secondary_accession": rec.get(
            "secondary_accession", ""
        ),
        "alias": rec.get("alias", ""),
        "title": rec.get("title", ""),
        "status": rec.get("status", "UNKNOWN"),
        "match_reason": reason,
    }


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
# Reports API (study-specific)
# -----------------------------------------------------------

_PROD_REPORTS_URL: Final = "https://www.ebi.ac.uk/ena/submit/report/projects"
_TEST_REPORTS_URL: Final = "https://wwwdev.ebi.ac.uk/ena/submit/report/projects"


def _normalize_study_report(
    report: dict[str, Any],
) -> dict[str, str]:
    """Normalise a raw study report dict."""
    return {
        "title": (
            report.get("title") or report.get("studyTitle") or report.get("STUDY_TITLE", "")
        ),
        "alias": report.get("alias") or report.get("studyAlias") or "",
        "accession": (
            report.get("accession")
            or report.get("studyAccession")
            or report.get("report", {}).get("id", "")
        ),
        "secondary_accession": report.get("secondaryAccession") or report.get("secondaryId", ""),
        "status": report.get("releaseStatus", "UNKNOWN"),
    }


def fetch_account_studies(
    auth: HTTPBasicAuth,
    use_test: bool = False,
    max_results: int = 5000,
) -> list[dict[str, str]]:
    """Fetch all projects from the Webin Reports API.

    Args:
        auth: HTTP basic-auth credentials.
        use_test: Try the test endpoint before production.
        max_results: Maximum number of results to request.

    Returns:
        List of normalised study dicts.
    """
    return fetch_account_records(
        auth,
        use_test=use_test,
        prod_url=_PROD_REPORTS_URL,
        test_url=_TEST_REPORTS_URL,
        normalizer=_normalize_study_report,
        entity_label="studies",
        max_results=max_results,
    )


def find_duplicate_studies(
    new_studies: list[dict[str, Any]],
    account_studies: list[dict[str, str]],
) -> dict[int, dict[str, str]]:
    """Check new studies against existing account studies.

    Args:
        new_studies: Studies the user wants to submit.
        account_studies: Existing studies in the account.

    Returns:
        Mapping of index to matching study info.
    """
    return find_duplicates_by_alias_title(
        new_studies, account_studies,
        title_field="STUDY_TITLE",
        entity_label="studies",
    )


# -----------------------------------------------------------
# XML construction
# -----------------------------------------------------------


def build_submission_xml(
    studies: list[dict[str, Any]],
    hold_until: str | None = None,
    action: str = "ADD",
) -> ET.Element:
    """Build a WEBIN XML document for submitting studies.

    Each study in the input list is converted to a PROJECT
    element.

    Args:
        studies: Study metadata dicts.
        hold_until: Optional hold-until date string
            (``YYYY-MM-DD``).
        action: Submission action — ``"ADD"`` for new studies
            or ``"MODIFY"`` to update existing ones.

    Returns:
        Root ``<WEBIN>`` element.
    """
    webin = ET.Element("WEBIN")

    # SUBMISSION_SET
    submission_set = ET.SubElement(webin, "SUBMISSION_SET")
    submission = ET.SubElement(
        submission_set, "SUBMISSION",
    )
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
        _add_project_element(project_set, study)

    return webin


def _add_project_element(
    project_set: ET.Element,
    study: dict[str, Any],
) -> None:
    """Append a ``<PROJECT>`` element to *project_set*."""
    alias = study.get(
        "alias",
        study.get("STUDY_TITLE", "").replace(" ", "_")[:50],
    )
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
# Structural XML validation (study-specific)
# -----------------------------------------------------------


def _validate_study_xml_structure(
    xml_bytes: bytes,
    messages: list[str],
) -> tuple[bool, list[str]]:
    """Structural check for study XML."""
    try:
        tree = ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        messages.append(
            f"ERROR: XML is not well-formed: {exc}"
        )
        return False, messages

    messages.append(
        "XML is well-formed (basic check passed)"
    )

    project_set = tree.find("PROJECT_SET")
    if project_set is None:
        messages.append("ERROR: Missing PROJECT_SET element")
        return False, messages

    projects = project_set.findall("PROJECT")
    if not projects:
        messages.append("ERROR: No PROJECT elements found")
        return False, messages

    for proj in projects:
        alias = proj.get("alias", "<no alias>")
        title = proj.find("TITLE")
        if title is None or not title.text:
            messages.append(f"ERROR: PROJECT '{alias}' missing TITLE")
            return False, messages
        sp = proj.find("SUBMISSION_PROJECT")
        if sp is None:
            messages.append(f"ERROR: PROJECT '{alias}' missing SUBMISSION_PROJECT")
            return False, messages
        messages.append(f"OK: PROJECT '{alias}' has required elements")

    return True, messages


def validate_study_xml(
    xml_bytes: bytes,
) -> tuple[bool, list[str]]:
    """Validate study XML structure.

    Args:
        xml_bytes: Serialised XML document.

    Returns:
        Tuple of (*is_valid*, *messages*).
    """
    return validate_xml_against_xsd(
        xml_bytes,
        fallback_checker=_validate_study_xml_structure,
    )


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
    result_key: str,
    env_label: str,
    dry_run: bool,
) -> bool:
    """Validate, optionally submit, and parse one batch.

    Args:
        base_url: ENA Webin v2 submission base URL.
        auth: HTTP basic-auth credentials.
        xml_bytes: Serialised XML submission document.
        action: Label for log messages (``"ADD"`` or
            ``"MODIFY"``).
        results: Results dict to accumulate into.
        result_key: Key under which successes are stored.
        env_label: ``"TEST"`` or ``"PRODUCTION"``.
        dry_run: If ``True``, skip the actual submission.

    Returns:
        ``True`` if the batch succeeded (or dry run).
    """
    xml_valid, xml_messages = validate_study_xml(xml_bytes)
    for msg in xml_messages:
        logger.info("  %s", msg)
    if not xml_valid:
        logger.error("XML validation FAILED (%s) — aborting submission", action)
        return False

    logger.info("XML validation PASSED (%s)", action)

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
            results[result_key].append(acc)
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
    help="Submit raw-reads, assembly and genome studies to ENA via the Webin REST API v2.",
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
    "--log", "log_file",
    type=click.Path(path_type=Path),
    default=None,
    help="Path to log file",
)
@click.option(
    "--output",
    type=click.Path(path_type=Path),
    default=None,
    help="Path to write JSON accession results (default: stdout)",
)
@click.option(
    "--max-results",
    default=5000,
    help="Maximum number of projects to fetch from the Reports API for duplicate checking",
)
@click.option(
    "--dry-run",
    is_flag=True, default=False,
    help="Validate and build XML but do not submit to ENA",
)
@click.option(
    "--automated",
    is_flag=True, default=False,
    help="Skip duplicate detection against the Webin Reports API (for automated pipelines)",
)
@click.option(
    "--force",
    is_flag=True, default=False,
    help="Submit duplicate studies using the MODIFY action to overwrite existing ENA records,"
    " instead of skipping them",
)
def main(
    input_file: Path,
    use_test: bool,
    hold_until: str | None,
    log_file: Path | None,
    output: Path | None,
    max_results: int,
    dry_run: bool,
    automated: bool,
    force: bool,
) -> None:
    """Submit studies to ENA via the Webin REST API v2."""
    setup_logging(log_file)
    username, password = get_credentials()

    env_label = "TEST" if use_test else "PRODUCTION"
    logger.info("ENA Study Submission — environment: %s", env_label)
    base_url = get_base_url(use_test)
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

    # -- Step 2: Check for duplicates --------------------
    if automated:
        logger.info("Automated mode: skipping duplicate detection")
        duplicates: dict[int, dict[str, Any]] = {}
    else:
        account_studies = fetch_account_studies(
            auth, use_test=use_test,
            max_results=max_results,
        )
        for ps in account_studies:
            logger.info(
                "  Account study: %s | alias=%s | title=%s | status=%s",
                ps["accession"], ps["alias"], ps["title"], ps["status"],
            )
        duplicates = find_duplicate_studies(
            studies, account_studies,
        )

    results: dict[str, list[dict[str, Any]]] = {
        "duplicates": [],
        "submitted": [],
        "modified": [],
        "failed": [],
    }

    studies_to_modify: list[dict[str, Any]] = []
    if duplicates:
        action_label = "will be re-submitted with MODIFY" if force else "will NOT be submitted"
        logger.warning(
            "Found %d duplicate(s) — %s:",
            len(duplicates), action_label,
        )
        for idx, dup_info in duplicates.items():
            study_title = studies[idx].get("STUDY_TITLE", f"study[{idx}]")
            logger.warning(
                "  DUPLICATE: '%s' matches existing %s (accession: %s)",
                study_title, dup_info["match_reason"], dup_info["accession"],
            )
            results["duplicates"].append({
                "input_index": idx,
                "title": study_title,
                "alias": studies[idx].get("alias", ""),
                "existing_accession": dup_info["accession"],
                "existing_secondary_accession": dup_info.get("secondary_accession", ""),
                "match_reason": dup_info["match_reason"],
            })
            if force:
                study_copy = dict(studies[idx])
                existing_alias = dup_info.get("alias", "")
                if existing_alias:
                    study_copy["alias"] = existing_alias
                studies_to_modify.append(study_copy)

    studies_to_submit = [
        s for i, s in enumerate(studies)
        if i not in duplicates
    ]

    if not studies_to_submit and not studies_to_modify:
        logger.info("No studies to submit (all are duplicates or input is empty)")
        write_results(results, output)
        return

    logger.info(
        "%d new study/studies to ADD, %d duplicate(s) to MODIFY",
        len(studies_to_submit), len(studies_to_modify),
    )

    overall_ok = True

    # -- Step 3: ADD new studies -------------------------
    if studies_to_submit:
        logger.info("Building ADD XML for %d new study/studies...", len(studies_to_submit))
        xml_root = build_submission_xml(studies_to_submit, hold_until=hold_until, action="ADD")
        xml_bytes = xml_to_bytes(xml_root)
        logger.debug("Generated XML (ADD):\n%s", xml_bytes.decode("utf-8"))
        logger.info("XML document size (ADD): %d bytes", len(xml_bytes))
        ok = _do_submission(
            base_url, auth, xml_bytes,
            action="ADD",
            results=results,
            result_key="submitted",
            env_label=env_label,
            dry_run=dry_run,
        )
        overall_ok = overall_ok and ok

    # -- Step 4: MODIFY duplicate studies (--force) ------
    if studies_to_modify:
        logger.info("Building MODIFY XML for %d duplicate(s)...", len(studies_to_modify))
        xml_root = build_submission_xml(studies_to_modify, hold_until=hold_until, action="MODIFY")
        xml_bytes = xml_to_bytes(xml_root)
        logger.debug("Generated XML (MODIFY):\n%s", xml_bytes.decode("utf-8"))
        logger.info("XML document size (MODIFY): %d bytes", len(xml_bytes))
        ok = _do_submission(
            base_url, auth, xml_bytes,
            action="MODIFY",
            results=results,
            result_key="modified",
            env_label=env_label,
            dry_run=dry_run,
        )
        overall_ok = overall_ok and ok

    if not overall_ok:
        sys.exit(1)

    # -- Step 5: Output results --------------------------
    write_results(results, output)

    logger.info("=" * 60)
    logger.info("SUBMISSION SUMMARY")
    logger.info(
        "  Duplicates skipped: %d", len(results["duplicates"]) - len(results["modified"]),
    )
    for d in results["duplicates"]:
        logger.info("    %s -> %s", d["title"], d["existing_accession"])
    logger.info("  Newly submitted (ADD): %d", len(results["submitted"]))
    for s in results["submitted"]:
        ext = s.get("external_accession", "")
        ext_suffix = f" ({ext})" if ext else ""
        logger.info("    %s -> %s%s", s["alias"], s["accession"], ext_suffix)
    logger.info("  Modified (MODIFY): %d", len(results["modified"]))
    for m in results["modified"]:
        ext = m.get("external_accession", "")
        ext_suffix = f" ({ext})" if ext else ""
        logger.info("    %s -> %s%s", m["alias"], m["accession"], ext_suffix)
    logger.info("=" * 60)


if __name__ == "__main__":
    main()  # type: ignore[call-arg]
