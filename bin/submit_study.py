#!/usr/bin/env python3
"""Submit studies to ENA via the Webin REST API v2.

Thin CLI wrapper: load/validate seqsubmit's own JSON/CSV/TSV study format,
adapt its field names to the ones ena_submission_toolkit expects, then
delegate everything else (XML building, XSD validation, submission, receipt
parsing) to ena_submission_toolkit + ena_api.

Credentials are read from environment variables::

    export ENA_WEBIN=Webin-XXXXX
    export ENA_WEBIN_PASSWORD=SECRET

Usage::

    python bin/submit_study.py --input studies.json --test
    python bin/submit_study.py --input studies.json --validate
"""

from __future__ import annotations

import csv
import hashlib
import json
import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Final

import click
import httpx
from ena_api import WebinClient, WebinConfig
from ena_submission_toolkit import common, xsd_dir
from ena_submission_toolkit.submit_study import build_manifest, submit_batch

logging.basicConfig(format="%(levelname)s: %(message)s", level=logging.INFO, stream=sys.stderr)
logger = logging.getLogger("seqsubmit.submit_study")

# -----------------------------------------------------------------
# Study metadata field definitions (seqsubmit's own vocabulary)
# -----------------------------------------------------------------

#: Fields that must be present and non-empty in every record.
_REQUIRED_FIELDS: Final[frozenset[str]] = frozenset({"alias", "study_title"})

#: Fields that are recognised but optional.
_OPTIONAL_FIELDS: Final[frozenset[str]] = frozenset({
    "project_name",
    "study_abstract",
    "study_description",
    "existing_study_type",
    "new_study_type",
})

_ALL_FIELDS: Final[frozenset[str]] = _REQUIRED_FIELDS | _OPTIONAL_FIELDS

#: seqsubmit's own field names -> the ena_submission_toolkit field names
#: that ena_submission_toolkit.submit_study._add_project_element expects.
#: "alias"/"existing_study_type"/"new_study_type" already match and pass
#: through unchanged.
_FIELD_NAME_MAP: Final[dict[str, str]] = {
    "study_title": "STUDY_TITLE",
    "study_abstract": "STUDY_ABSTRACT",
    "study_description": "STUDY_DESCRIPTION",
    "project_name": "CENTER_PROJECT_NAME",
}


def _adapt_record(record: dict[str, Any]) -> dict[str, Any]:
    """Rename a seqsubmit-vocabulary record to ena_submission_toolkit's."""
    return {_FIELD_NAME_MAP.get(k, k): v for k, v in record.items()}


# -----------------------------------------------------------------
# File loading (JSON, CSV, TSV) — seqsubmit's own formats, not the
# DataHarmonizer "Container" shape ena_submission_toolkit's own CLI expects.
# -----------------------------------------------------------------


def extract_records_from_tabular(filepath: str | Path, delimiter: str = ",") -> list[dict[str, str]]:
    """Extract record dicts from a CSV or TSV file (only known columns kept)."""
    records = []
    with open(filepath, newline="", encoding="utf-8") as fh:
        for line in csv.DictReader(fh, delimiter=delimiter):
            record = {col: line[col].strip() for col in _ALL_FIELDS if line.get(col, "").strip()}
            if record:
                records.append(record)
    return records


def extract_records_from_json(filepath: str | Path) -> list[dict[str, Any]]:
    """Extract record dicts from a JSON file (a plain list, or a single record object)."""
    input_data = json.loads(Path(filepath).read_text())
    if isinstance(input_data, list):
        return input_data
    if isinstance(input_data, dict):
        return [input_data]
    return []


def load_and_validate_input_file(filepath: str | Path) -> list[dict[str, Any]]:
    """Load records from a supported file format and check required fields.

    Raises:
        ValueError: Unrecognised file format, empty file, or a record missing
            a required field.
    """
    ext = Path(filepath).suffix.lower()
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


def _test_mode_alias(alias: str) -> str:
    """Append an 8-character timestamp hash for uniqueness in test submissions."""
    timestamp_hash = hashlib.md5(datetime.now().isoformat().encode()).hexdigest()[:8]
    return f"{alias}_{timestamp_hash}"


# -----------------------------------------------------------------
# Main
# -----------------------------------------------------------------


@click.command(help="Submit studies to ENA via the Webin REST API v2.")
@click.option(
    "--input", "input_file",
    required=True, type=click.Path(exists=True, path_type=Path),
    help="Path to study metadata file (JSON, CSV, or TSV)",
)
@click.option(
    "--xsd", "xsd_dir_override",
    default=None, type=click.Path(exists=True, file_okay=False, path_type=Path),
    help="Directory containing ENA.project.xsd and SRA.common.xsd (default: bundled with ena-submission-toolkit)",
)
@click.option("--test", "use_test", is_flag=True, default=False, help="Use the ENA test service (submissions are discarded daily)")
@click.option("--hold-until", default=None, help="Hold studies private until this date (YYYY-MM-DD, max 2 years from now)")
@click.option("--output", type=click.Path(path_type=Path), default=None, help="Path to write JSON accession results (default: stdout)")
@click.option("--validate", "dry_run", is_flag=True, default=False, help="Validate and build XML but do not submit to ENA")
def main(
    input_file: Path,
    xsd_dir_override: Path | None,
    use_test: bool,
    hold_until: str | None,
    output: Path | None,
    dry_run: bool,
) -> None:
    """Submit studies to ENA via the Webin REST API v2."""
    env_label = "TEST" if use_test else "PRODUCTION"
    logger.info("ENA Study Submission — environment: %s", env_label)
    xsd_path = xsd_dir_override or xsd_dir()

    if hold_until:
        try:
            common.validate_hold_until(hold_until)
        except ValueError as exc:
            raise click.BadParameter(str(exc), param_hint="--hold-until") from exc

    logger.info("Loading input: %s", input_file)
    try:
        studies = load_and_validate_input_file(input_file)
    except ValueError as exc:
        raise click.BadParameter(str(exc), param_hint="--input") from exc
    logger.info("Loaded %d study/studies from input", len(studies))

    batch = []
    for study in studies:
        adapted = _adapt_record(study)
        if use_test:
            adapted["alias"] = _test_mode_alias(adapted.get("alias", ""))
        batch.append(adapted)

    if dry_run:
        xml_bytes = build_manifest(batch, hold_until=hold_until, action="ADD")
        logger.info("DRY RUN — skipping submission")
        logger.info("Generated XML:\n%s", xml_bytes.decode("utf-8"))
        return

    try:
        username, password = common.get_credentials()
    except ValueError as exc:
        logger.error("%s", exc)
        raise SystemExit(1) from exc
    client = WebinClient(config=WebinConfig(webin_id=username, password=password, test=use_test))
    try:
        success, accessions = submit_batch(
            batch, "ADD", xsd=xsd_path, hold_until=hold_until, client=client, env_label=env_label,
        )
    except (ValueError, httpx.HTTPStatusError) as exc:
        logger.error("%s", exc)
        raise SystemExit(1) from exc
    finally:
        client.close()

    results: dict[str, list[dict[str, Any]]] = {
        "submitted": accessions if success else [],
        "failed": [] if success else accessions,
    }
    common.write_results(results, output)

    logger.info("=" * 60)
    logger.info("SUBMISSION SUMMARY")
    logger.info("  Submitted (ADD): %d", len(results["submitted"]))
    for submission in results["submitted"]:
        ext = submission.get("external_accession", "")
        logger.info("    %s -> %s%s", submission["alias"], submission["accession"], f" ({ext})" if ext else "")
    logger.info("=" * 60)

    if not success:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
