"""Shared utilities for ENA submission scripts.

Provide logging, credential management, file loading,
XSD structural validation, Reports API access, duplicate
detection, XML serialisation, and result output used by
``submit_study.py``, ``submit_sample.py``, and
``submit_reads.py``.
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

# All loggers in the ENA submission scripts are children of
# this root, so configuring it once propagates to all.
_LOGGER_NAME: Final = "ena_submit"

logger = logging.getLogger(_LOGGER_NAME)


# -----------------------------------------------------------
# Constants
# -----------------------------------------------------------

PROD_URL: Final = (
    "https://www.ebi.ac.uk/ena/submit/webin-v2"
)
TEST_URL: Final = (
    "https://wwwdev.ebi.ac.uk/ena/submit/webin-v2"
)

_MAX_HOLD_YEARS: Final = 2


# -----------------------------------------------------------
# Logging
# -----------------------------------------------------------


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
    username = os.environ.get("ENA_USERNAME", "").strip()
    password = os.environ.get("ENA_PASSWORD", "").strip()
    if not username or not password:
        logger.error(
            "ENA_USERNAME and ENA_PASSWORD environment"
            " variables must be set",
        )
        sys.exit(1)
    return username, password


# -----------------------------------------------------------
# ENA API helpers
# -----------------------------------------------------------


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
            f"Invalid date format: {hold_until!r}."
            " Expected YYYY-MM-DD."
        ) from None

    today = datetime.date.today()
    max_date = today.replace(year=today.year + _MAX_HOLD_YEARS)

    if hold_date > max_date:
        raise click.BadParameter(
            f"Hold date {hold_until} is more than"
            f" {_MAX_HOLD_YEARS} years from today"
            f" ({today}). Maximum allowed: {max_date}."
        )

    if hold_date <= today:
        raise click.BadParameter(
            f"Hold date {hold_until} is not in the"
            f" future (today is {today})."
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
    fragment_tag: str | None = None,
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
        fragment_tag: Unused; kept for API compatibility.
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
                    logger.info(
                        "Extracted records from"
                        " Container.%s",
                        key,
                    )
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

    req = requests.Request(
        "GET", url, params=params, auth=auth,
    )
    prepared = req.prepare()
    logger.debug(
        'curl -u %s:*** "%s"',
        auth.username, prepared.url,
    )

    try:
        resp = requests.get(
            url, params=params, auth=auth, timeout=60,
        )
        logger.info(
            "Reports API at %s returned %s",
            url, resp.status_code,
        )
        resp.raise_for_status()
        return resp.json()

    except requests.exceptions.HTTPError as exc:
        status = (
            exc.response.status_code
            if exc.response is not None
            else "unknown"
        )
        if status == 404:
            logger.info(
                "Reports API at %s returned 404"
                " — no records yet",
                url,
            )
            return []
        if status in (401, 403):
            logger.warning(
                "Reports API at %s returned %s"
                " — endpoint may not be available"
                " or credentials may differ",
                url, status,
            )
            return None
        logger.warning(
            "Reports API at %s returned HTTP %s",
            url, status,
        )
        return None

    except requests.exceptions.RequestException as exc:
        logger.warning(
            "Reports API at %s failed: %s", url, exc,
        )
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
        logger.info(
            "Fetching account %s from: %s",
            entity_label, url,
        )
        raw = fetch_from_reports_endpoint(
            url, auth, max_results,
        )
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

        logger.info(
            "Found %d %s in account",
            len(records), entity_label,
        )
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
        "Checking %d new %s against"
        " %d existing account %s...",
        total, entity_label,
        len(account_records), entity_label,
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
                logger.info(
                    "All %s are duplicates"
                    " — skipping further checks",
                    entity_label,
                )
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
