#!/usr/bin/env python3
"""Submit studies to ENA via the Webin REST API v2.

Read a DataHarmonizer export containing study metadata,
validate it against a LinkML schema and an XSD schema,
check for duplicate studies already registered under the
Webin account, construct an XML submission document, and
submit new studies to ENA.

Credentials are read from environment variables to avoid
secrets appearing in shell history or process listings::

    export ENA_USERNAME=Webin-XXXXX
    export ENA_PASSWORD=SECRET

Usage::

    python scripts/submit_study.py \\
        --input studies.json \\
        --linkml schemas/SRA_study.yaml \\
        --xsd assets/ena_schema \\
        --test

    # With hold date (max 2 years):
    python scripts/submit_study.py \\
        --input studies.json \\
        --linkml schemas/SRA_study.yaml \\
        --xsd assets/ena_schema \\
        --hold-until 2028-01-01

    # Log to file:
    python scripts/submit_study.py \\
        --input studies.json \\
        --linkml schemas/SRA_study.yaml \\
        --xsd assets/ena_schema \\
        --test --log submission.log
"""

from __future__ import annotations

import logging
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Final

import pendulum
import requests
import typer
from requests.auth import HTTPBasicAuth

import ena_common as common

app = typer.Typer(
    help="Submit studies to ENA via the Webin REST API v2.",
)

logger = logging.getLogger("ena_submit.study")


# -----------------------------------------------------------
# Reports API (study-specific)
# -----------------------------------------------------------

_PROD_REPORTS_URL: Final = (
    "https://www.ebi.ac.uk/ena/submit/report/projects"
)
_TEST_REPORTS_URL: Final = (
    "https://wwwdev.ebi.ac.uk/ena/submit/report/projects"
)


def _normalize_study_report(
    report: dict[str, Any],
) -> dict[str, str]:
    """Normalise a raw study report dict."""
    return {
        "title": (
            report.get("title")
            or report.get("studyTitle")
            or report.get("STUDY_TITLE", "")
        ),
        "alias": (
            report.get("alias")
            or report.get("studyAlias")
            or ""
        ),
        "accession": (
            report.get("accession")
            or report.get("studyAccession")
            or report.get("report", {}).get("id", "")
        ),
        "secondary_accession": (
            report.get("secondaryAccession")
            or report.get("secondaryId", "")
        ),
        "status": report.get(
            "releaseStatus", "UNKNOWN"
        ),
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
    return common.fetch_account_records(
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
    return common.find_duplicates_by_alias_title(
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
    sub_alias = (
        "study-submission-"
        + pendulum.now().format("YYYYMMDD-HHmmss")
    )
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
# XSD validation (study-specific fallback)
# -----------------------------------------------------------


def _validate_study_xml_structure(
    xml_bytes: bytes,
    messages: list[str],
) -> tuple[bool, list[str]]:
    """Fallback structural check for study XML."""
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
        messages.append(
            "ERROR: Missing PROJECT_SET element"
        )
        return False, messages

    projects = project_set.findall("PROJECT")
    if not projects:
        messages.append("ERROR: No PROJECT elements found")
        return False, messages

    for proj in projects:
        alias = proj.get("alias", "<no alias>")
        title = proj.find("TITLE")
        if title is None or not title.text:
            messages.append(
                f"ERROR: PROJECT '{alias}' missing TITLE"
            )
            return False, messages
        sp = proj.find("SUBMISSION_PROJECT")
        if sp is None:
            messages.append(
                f"ERROR: PROJECT '{alias}'"
                " missing SUBMISSION_PROJECT"
            )
            return False, messages
        messages.append(
            f"OK: PROJECT '{alias}' has required elements"
        )

    return True, messages


def validate_against_xsd(
    xml_bytes: bytes,
    xsd_dir: str | Path,
) -> tuple[bool, list[str]]:
    """Validate study XML against ENA.project.xsd.

    Args:
        xml_bytes: Serialised XML document.
        xsd_dir: Directory containing ``ENA.project.xsd``
            and ``SRA.common.xsd``.

    Returns:
        Tuple of (*is_valid*, *messages*).
    """
    return common.validate_xml_against_xsd(
        xml_bytes, xsd_dir,
        xsd_filename="ENA.project.xsd",
        fragment_tag="PROJECT_SET",
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
    success = (
        receipt_root.get("success", "false").lower()
        == "true"
    )
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
            "holdUntilDate": proj.get(
                "holdUntilDate", ""
            ),
        }
        ext = proj.find("EXT_ID")
        if ext is not None:
            acc_info["external_accession"] = ext.get(
                "accession", ""
            )
            acc_info["external_type"] = ext.get(
                "type", ""
            )
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
    xsd: Path,
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
        xsd: Directory containing the XSD files.
        action: Label for log messages (``"ADD"`` or
            ``"MODIFY"``).
        results: Results dict to accumulate into.
        result_key: Key under which successes are stored.
        env_label: ``"TEST"`` or ``"PRODUCTION"``.
        dry_run: If ``True``, skip the actual submission.

    Returns:
        ``True`` if the batch succeeded (or dry run).
    """
    xsd_valid, xsd_messages = validate_against_xsd(
        xml_bytes, xsd,
    )
    for msg in xsd_messages:
        logger.info("  %s", msg)
    if not xsd_valid:
        logger.error(
            "XSD validation FAILED (%s)"
            " — aborting submission", action,
        )
        return False

    logger.info("XSD validation PASSED (%s)", action)

    if dry_run:
        logger.info(
            "DRY RUN — skipping %s submission", action,
        )
        logger.info(
            "Generated XML:\n%s",
            xml_bytes.decode("utf-8"),
        )
        return True

    logger.info(
        "Submitting %s to ENA (%s)...", action, env_label,
    )
    try:
        receipt_root = common.submit_xml(
            base_url, auth, xml_bytes,
        )
    except requests.exceptions.HTTPError as exc:
        logger.error(
            "HTTP error during %s submission: %s",
            action, exc,
        )
        if exc.response is not None:
            logger.error(
                "Response body: %s", exc.response.text,
            )
        return False

    success, accessions, receipt_messages = (
        parse_xml_receipt(receipt_root)
    )
    for msg in receipt_messages:
        logger.info("  Receipt: %s", msg)

    if success:
        logger.info("%s SUCCESSFUL", action)
        for acc in accessions:
            ext = acc.get("external_accession", "")
            ext_suffix = (
                f" (study: {ext})" if ext else ""
            )
            logger.info(
                "  %s: alias=%s accession=%s"
                " status=%s%s",
                action, acc["alias"], acc["accession"],
                acc["status"], ext_suffix,
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


@app.command()
def main(
    input_file: Path = typer.Option(
        ..., "--input", exists=True,
        help="Path to study metadata file"
        " (JSON, CSV, TSV, XLS, or XLSX)",
    ),
    linkml: Path = typer.Option(
        ..., exists=True,
        help="Path to LinkML YAML schema"
        " (e.g. schemas/SRA_study.yaml)",
    ),
    xsd: Path = typer.Option(
        ..., exists=True,
        file_okay=False, resolve_path=True,
        help="Directory containing ENA.project.xsd"
        " and SRA.common.xsd",
    ),
    test: bool = typer.Option(
        False, "--test",
        help="Use the ENA test service"
        " (submissions are discarded daily)",
    ),
    hold_until: str | None = typer.Option(
        None, "--hold-until",
        help="Hold studies private until this date"
        " (YYYY-MM-DD, max 2 years from now)",
    ),
    log: Path | None = typer.Option(
        None, help="Path to log file",
    ),
    output: Path | None = typer.Option(
        None,
        help="Path to write JSON accession results"
        " (default: stdout)",
    ),
    max_results: int = typer.Option(
        5000, "--max-results",
        help="Maximum number of projects to fetch"
        " from the Reports API for duplicate"
        " checking",
    ),
    dry_run: bool = typer.Option(
        False, "--dry-run",
        help="Validate and build XML but do not"
        " submit to ENA",
    ),
    automated: bool = typer.Option(
        False, "--automated",
        help="Skip duplicate detection against the"
        " Webin Reports API (for automated pipelines)",
    ),
    force: bool = typer.Option(
        False, "--force",
        help="Submit duplicate studies using the MODIFY"
        " action to overwrite existing ENA records,"
        " instead of skipping them",
    ),
) -> None:
    """Submit studies to ENA via the Webin REST API v2."""
    common.setup_logging(log)
    username, password = common.get_credentials()

    env_label = "TEST" if test else "PRODUCTION"
    logger.info(
        "ENA Study Submission — environment: %s",
        env_label,
    )
    base_url = common.get_base_url(test)
    auth = HTTPBasicAuth(username, password)
    logger.debug("Auth username: %s", username)

    if hold_until:
        common.validate_hold_until(hold_until)

    # -- Step 1: Load input file -------------------------
    logger.info("Loading input: %s", input_file)
    studies = common.load_input_file(
        input_file, json_record_keys=_JSON_RECORD_KEYS,
    )
    if studies is None:
        logger.error(
            "Unsupported file format."
            " Supported: .json, .csv, .tsv, .xlsx, .xls",
        )
        sys.exit(1)

    logger.info(
        "Loaded %d study/studies from input",
        len(studies),
    )

    # -- Step 2: Check for duplicates --------------------
    if automated:
        logger.info(
            "Automated mode: skipping duplicate detection",
        )
        duplicates: dict[int, dict[str, Any]] = {}
    else:
        account_studies = fetch_account_studies(
            auth, use_test=test,
            max_results=max_results,
        )
        for ps in account_studies:
            logger.info(
                "  Account study: %s | alias=%s"
                " | title=%s | status=%s",
                ps["accession"], ps["alias"],
                ps["title"], ps["status"],
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
        action_label = (
            "will be re-submitted with MODIFY"
            if force else "will NOT be submitted"
        )
        logger.warning(
            "Found %d duplicate(s) — %s:",
            len(duplicates), action_label,
        )
        for idx, dup_info in duplicates.items():
            study_title = studies[idx].get(
                "STUDY_TITLE", f"study[{idx}]",
            )
            logger.warning(
                "  DUPLICATE: '%s' matches existing %s"
                " (accession: %s)",
                study_title,
                dup_info["match_reason"],
                dup_info["accession"],
            )
            results["duplicates"].append({
                "input_index": idx,
                "title": study_title,
                "alias": studies[idx].get("alias", ""),
                "existing_accession": (
                    dup_info["accession"]
                ),
                "existing_secondary_accession": (
                    dup_info.get(
                        "secondary_accession", ""
                    )
                ),
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
        logger.info(
            "No studies to submit"
            " (all are duplicates or input is empty)",
        )
        common.write_results(results, output)
        return

    logger.info(
        "%d new study/studies to ADD,"
        " %d duplicate(s) to MODIFY",
        len(studies_to_submit), len(studies_to_modify),
    )

    # -- Step 3: Validate against LinkML -----------------
    logger.info("Loading LinkML schema: %s", linkml)
    schema = common.load_linkml_schema(linkml)

    logger.info(
        "Validating input against LinkML schema...",
    )
    linkml_valid, linkml_messages = (
        common.validate_against_linkml(
            studies_to_submit + studies_to_modify, schema,
            label_fields=["STUDY_TITLE", "alias"],
            entity_name="study",
            unknown_field_note="will be ignored",
        )
    )
    for msg in linkml_messages:
        logger.info("  %s", msg)

    if not linkml_valid:
        logger.error(
            "LinkML validation FAILED"
            " — aborting submission",
        )
        sys.exit(1)

    logger.info("LinkML validation PASSED")

    overall_ok = True

    # -- Steps 4-7: ADD new studies ----------------------
    if studies_to_submit:
        logger.info(
            "Building ADD XML for %d new study/studies...",
            len(studies_to_submit),
        )
        xml_root = build_submission_xml(
            studies_to_submit, hold_until=hold_until,
            action="ADD",
        )
        xml_bytes = common.xml_to_bytes(xml_root)
        logger.debug(
            "Generated XML (ADD):\n%s",
            xml_bytes.decode("utf-8"),
        )
        logger.info(
            "XML document size (ADD): %d bytes",
            len(xml_bytes),
        )
        ok = _do_submission(
            base_url, auth, xml_bytes, xsd,
            action="ADD",
            results=results,
            result_key="submitted",
            env_label=env_label,
            dry_run=dry_run,
        )
        overall_ok = overall_ok and ok

    # -- Steps 4-7: MODIFY duplicate studies (--force) ---
    if studies_to_modify:
        logger.info(
            "Building MODIFY XML for %d duplicate(s)...",
            len(studies_to_modify),
        )
        xml_root = build_submission_xml(
            studies_to_modify, hold_until=hold_until,
            action="MODIFY",
        )
        xml_bytes = common.xml_to_bytes(xml_root)
        logger.debug(
            "Generated XML (MODIFY):\n%s",
            xml_bytes.decode("utf-8"),
        )
        logger.info(
            "XML document size (MODIFY): %d bytes",
            len(xml_bytes),
        )
        ok = _do_submission(
            base_url, auth, xml_bytes, xsd,
            action="MODIFY",
            results=results,
            result_key="modified",
            env_label=env_label,
            dry_run=dry_run,
        )
        overall_ok = overall_ok and ok

    if not overall_ok:
        sys.exit(1)

    # -- Step 8: Output results --------------------------
    common.write_results(results, output)

    logger.info("=" * 60)
    logger.info("SUBMISSION SUMMARY")
    logger.info(
        "  Duplicates skipped: %d",
        len(results["duplicates"])
        - len(results["modified"]),
    )
    for d in results["duplicates"]:
        logger.info(
            "    %s -> %s",
            d["title"], d["existing_accession"],
        )
    logger.info(
        "  Newly submitted (ADD): %d",
        len(results["submitted"]),
    )
    for s in results["submitted"]:
        ext = s.get("external_accession", "")
        ext_suffix = f" ({ext})" if ext else ""
        logger.info(
            "    %s -> %s%s",
            s["alias"], s["accession"], ext_suffix,
        )
    logger.info(
        "  Modified (MODIFY): %d",
        len(results["modified"]),
    )
    for m in results["modified"]:
        ext = m.get("external_accession", "")
        ext_suffix = f" ({ext})" if ext else ""
        logger.info(
            "    %s -> %s%s",
            m["alias"], m["accession"], ext_suffix,
        )
    logger.info("=" * 60)


if __name__ == "__main__":
    app()
