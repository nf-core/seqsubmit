#!/usr/bin/env python3
"""Tests for submit_rawreads_study.py and ena_submit_common.py — study submission pipeline.

Usage:
    pytest bin/test_submit_rawreads_study.py -v
"""

from __future__ import annotations

import json
import os
import sys

import pytest

# Ensure the scripts directory is importable
sys.path.insert(0, os.path.dirname(__file__))

import ena_submit_common as common
from submit_rawreads_study import (
    build_submission_xml,
    find_duplicate_studies,
    validate_study_xml,
)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

FIXTURES_DIR = os.path.join(
    os.path.dirname(__file__), "..", "assets", "test-fixtures",
)
EXAMPLE_STUDY_JSON = os.path.join(FIXTURES_DIR, "example_study.json")
EXAMPLE_STUDY_CSV = os.path.join(FIXTURES_DIR, "example_study.csv")
EXAMPLE_STUDY_TSV = os.path.join(FIXTURES_DIR, "example_study.tsv")

_FIXTURES_PRESENT = os.path.isfile(EXAMPLE_STUDY_JSON)
requires_fixtures = pytest.mark.skipif(
    not _FIXTURES_PRESENT,
    reason="example study fixtures not present in assets/test-fixtures/",
)

_JSON_RECORD_KEYS = ("studies", "data")

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def example_study_json():
    """Load the example study JSON fixture."""
    with open(EXAMPLE_STUDY_JSON) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# extract_records_from_json tests
# ---------------------------------------------------------------------------


class TestExtractRecordsFromJson:
    """Tests for extracting study rows from various JSON formats."""

    @requires_fixtures
    def test_dataharmonizer_container_format(self, example_study_json):
        """The example_study.json fixture uses DataHarmonizer Container format."""
        studies = common.extract_records_from_json(
            example_study_json, record_keys=_JSON_RECORD_KEYS,
        )
        assert studies is not None
        assert len(studies) == 1
        assert studies[0]["STUDY_TITLE"] == "MIMICC"
        assert studies[0]["existing_study_type"] == "Metagenomics"
        assert studies[0]["IS_PRIMARY"] == "YES"

    def test_plain_list(self):
        """Plain list input returns the list as-is."""
        data = [{"STUDY_TITLE": "Test Study", "IS_PRIMARY": "YES"}]
        studies = common.extract_records_from_json(
            data, record_keys=_JSON_RECORD_KEYS,
        )
        assert studies == data

    def test_dict_with_studies_key(self):
        """Dict with 'studies' key extracts the list."""
        data = {"studies": [{"STUDY_TITLE": "A"}, {"STUDY_TITLE": "B"}]}
        studies = common.extract_records_from_json(
            data, record_keys=_JSON_RECORD_KEYS,
        )
        assert len(studies) == 2

    def test_dict_with_data_key(self):
        """Dict with 'data' key extracts the list."""
        data = {"data": [{"STUDY_TITLE": "C"}]}
        studies = common.extract_records_from_json(
            data, record_keys=_JSON_RECORD_KEYS,
        )
        assert len(studies) == 1

    def test_single_study_object(self):
        """Single dict input is wrapped in a list."""
        data = {"STUDY_TITLE": "Single"}
        studies = common.extract_records_from_json(
            data, record_keys=_JSON_RECORD_KEYS,
        )
        assert len(studies) == 1
        assert studies[0]["STUDY_TITLE"] == "Single"

    def test_invalid_input(self):
        """Non-dict/list input returns None."""
        result = common.extract_records_from_json(
            "not a dict or list", record_keys=_JSON_RECORD_KEYS,
        )
        assert result is None

    def test_container_with_multiple_studies(self):
        """Container format with multiple studies extracts all."""
        data = {
            "Container": {
                "SRA_studys": [
                    {"STUDY_TITLE": "Study A"},
                    {"STUDY_TITLE": "Study B"},
                ],
            },
        }
        studies = common.extract_records_from_json(
            data, record_keys=_JSON_RECORD_KEYS,
        )
        assert len(studies) == 2


# ---------------------------------------------------------------------------
# XML building tests
# ---------------------------------------------------------------------------


class TestBuildSubmissionXml:
    """Tests for building ENA study submission XML."""

    def test_basic_xml_structure(self):
        """Built XML contains expected elements and attributes."""
        studies = [
            {
                "alias": "test-study",
                "STUDY_TITLE": "Test Study",
                "STUDY_ABSTRACT": "Abstract text.",
                "existing_study_type": "Metagenomics",
            },
        ]
        root = build_submission_xml(studies)
        xml_bytes = common.xml_to_bytes(root)
        xml_str = xml_bytes.decode("utf-8")
        assert "<PROJECT_SET>" in xml_str
        assert 'alias="test-study"' in xml_str
        assert "<TITLE>Test Study</TITLE>" in xml_str
        assert "<DESCRIPTION>Abstract text.</DESCRIPTION>" in xml_str
        assert "<SEQUENCING_PROJECT" in xml_str

    def test_hold_until_date(self):
        """Hold-until date appears in the submission XML."""
        studies = [{"STUDY_TITLE": "T", "alias": "a"}]
        root = build_submission_xml(studies, hold_until="2028-01-01")
        xml_bytes = common.xml_to_bytes(root)
        xml_str = xml_bytes.decode("utf-8")
        assert 'HoldUntilDate="2028-01-01"' in xml_str

    def test_structural_validation(self):
        """Built XML should pass structural validation."""
        studies = [
            {
                "alias": "val-test",
                "STUDY_TITLE": "Validation Test Study",
                "existing_study_type": "RNASeq",
            },
        ]
        root = build_submission_xml(studies)
        xml_bytes = common.xml_to_bytes(root)
        is_valid, messages = validate_study_xml(xml_bytes)
        for msg in messages:
            print(msg)
        assert is_valid


# ---------------------------------------------------------------------------
# Duplicate detection tests
# ---------------------------------------------------------------------------


class TestFindDuplicateStudies:
    """Tests for alias/title-based duplicate detection."""

    def _make_account_study(
        self,
        title: str = "",
        alias: str = "",
        accession: str = "PRJEB99",
        secondary_accession: str = "",
        status: str = "PRIVATE",
    ) -> dict[str, str]:
        """Build a normalised account study dict."""
        return {
            "title": title,
            "alias": alias,
            "accession": accession,
            "secondary_accession": secondary_accession,
            "status": status,
        }

    def test_no_duplicates(self):
        """No match when titles and aliases differ."""
        new = [{"STUDY_TITLE": "New Study", "alias": "new-1"}]
        account = [
            self._make_account_study(
                title="Other Study", alias="other-1",
            ),
        ]
        dups = find_duplicate_studies(new, account)
        assert len(dups) == 0

    def test_duplicate_by_title(self):
        """Exact title match flags a duplicate."""
        new = [{"STUDY_TITLE": "Existing Study"}]
        account = [
            self._make_account_study(
                title="Existing Study",
                accession="PRJEB99",
                status="PRIVATE",
            ),
        ]
        dups = find_duplicate_studies(new, account)
        assert 0 in dups
        assert dups[0]["accession"] == "PRJEB99"

    def test_duplicate_by_alias(self):
        """Alias match flags a duplicate even with different title."""
        new = [{"STUDY_TITLE": "New Title", "alias": "my-alias"}]
        account = [
            self._make_account_study(
                title="Different Title",
                alias="my-alias",
                accession="PRJEB60",
            ),
        ]
        dups = find_duplicate_studies(new, account)
        assert 0 in dups
        assert dups[0]["accession"] == "PRJEB60"
        assert "alias" in dups[0]["match_reason"]

    def test_alias_takes_precedence_over_title(self):
        """When alias matches, it is reported as the match reason."""
        new = [{"STUDY_TITLE": "Same Title", "alias": "same-alias"}]
        account = [
            self._make_account_study(
                title="Same Title",
                alias="same-alias",
                accession="PRJEB70",
            ),
        ]
        dups = find_duplicate_studies(new, account)
        assert 0 in dups
        assert "alias" in dups[0]["match_reason"]

    def test_partial_title_not_duplicate(self):
        """Partial title match does not count as a duplicate."""
        new = [{"STUDY_TITLE": "My Study"}]
        account = [
            self._make_account_study(
                title="My Study Extended Title",
            ),
        ]
        dups = find_duplicate_studies(new, account)
        assert len(dups) == 0

    def test_empty_account_no_duplicates(self):
        """Empty account list produces no duplicates."""
        new = [{"STUDY_TITLE": "Test", "alias": "t"}]
        dups = find_duplicate_studies(new, [])
        assert len(dups) == 0

    def test_empty_input_no_duplicates(self):
        """Empty input list produces no duplicates."""
        account = [
            self._make_account_study(title="Existing"),
        ]
        dups = find_duplicate_studies([], account)
        assert len(dups) == 0

    def test_study_without_title_or_alias_skipped(self):
        """Studies with no title or alias are not flagged."""
        new = [{}]
        account = [
            self._make_account_study(title="Something"),
        ]
        dups = find_duplicate_studies(new, account)
        assert len(dups) == 0

    def test_mixed_duplicates_and_new(self):
        """Mix of duplicate and new studies."""
        account = [
            self._make_account_study(
                title="Dup By Title",
                alias="dup-title",
                accession="PRJEB10",
            ),
            self._make_account_study(
                title="Other",
                alias="dup-alias",
                accession="PRJEB20",
            ),
        ]
        new = [
            {"STUDY_TITLE": "Dup By Title", "alias": "new-alias"},
            {"STUDY_TITLE": "New Title", "alias": "dup-alias"},
            {"STUDY_TITLE": "Brand New", "alias": "brand-new"},
        ]
        dups = find_duplicate_studies(new, account)
        assert 0 in dups  # title match
        assert 1 in dups  # alias match
        assert 2 not in dups  # new

    def test_all_duplicates_early_exit(self):
        """All studies being duplicates terminates early."""
        account = [
            self._make_account_study(
                title="A", accession="PRJEB1",
            ),
            self._make_account_study(
                title="B", accession="PRJEB2",
            ),
        ]
        new = [
            {"STUDY_TITLE": "A"},
            {"STUDY_TITLE": "B"},
        ]
        dups = find_duplicate_studies(new, account)
        assert len(dups) == 2


# ---------------------------------------------------------------------------
# File loading tests (JSON, CSV, TSV)
# ---------------------------------------------------------------------------

# The expected study data shared by all supported fixtures
EXPECTED_STUDY = {
    "IS_PRIMARY": "YES",
    "STUDY_TITLE": "MIMICC",
    "existing_study_type": "Metagenomics",
}


@requires_fixtures
class TestLoadInputFile:
    """Tests for loading study data from JSON, CSV, and TSV files."""

    def test_load_csv(self):
        """CSV file loads correctly."""
        studies = common.load_input_file(
            EXAMPLE_STUDY_CSV, json_record_keys=_JSON_RECORD_KEYS,
        )
        assert studies is not None
        assert len(studies) == 1
        for key, val in EXPECTED_STUDY.items():
            assert studies[0][key] == val

    def test_load_tsv(self):
        """TSV file loads correctly."""
        studies = common.load_input_file(
            EXAMPLE_STUDY_TSV, json_record_keys=_JSON_RECORD_KEYS,
        )
        assert studies is not None
        assert len(studies) == 1
        for key, val in EXPECTED_STUDY.items():
            assert studies[0][key] == val

    def test_load_json(self):
        """JSON file loads correctly."""
        studies = common.load_input_file(
            EXAMPLE_STUDY_JSON, json_record_keys=_JSON_RECORD_KEYS,
        )
        assert studies is not None
        assert len(studies) == 1
        for key, val in EXPECTED_STUDY.items():
            assert studies[0][key] == val

    def test_all_formats_produce_same_data(self):
        """All supported formats should produce the same core study fields."""
        all_studies = [
            common.load_input_file(
                path, json_record_keys=_JSON_RECORD_KEYS,
            )
            for path in [EXAMPLE_STUDY_JSON, EXAMPLE_STUDY_CSV, EXAMPLE_STUDY_TSV]
        ]
        for studies in all_studies:
            assert len(studies) == 1
            for key, val in EXPECTED_STUDY.items():
                assert studies[0][key] == val

    def test_unknown_extension_returns_none(self, tmp_path):
        """Unsupported file extension returns None."""
        unknown = tmp_path / "data.parquet"
        unknown.write_text("dummy")
        result = common.load_input_file(
            str(unknown), json_record_keys=_JSON_RECORD_KEYS,
        )
        assert result is None

    def test_csv_without_metadata_row(self, tmp_path):
        """A CSV with no metadata row should still work."""
        csvfile = tmp_path / "no_meta.csv"
        csvfile.write_text("STUDY_TITLE,IS_PRIMARY\nTest,YES\n")
        studies = common.load_input_file(
            str(csvfile), json_record_keys=_JSON_RECORD_KEYS,
        )
        assert len(studies) == 1
        assert studies[0]["STUDY_TITLE"] == "Test"
        assert studies[0]["IS_PRIMARY"] == "YES"

    def test_tabular_empty_values_omitted(self, tmp_path):
        """Empty cells in tabular files should be omitted."""
        csvfile = tmp_path / "sparse.csv"
        csvfile.write_text(
            "STUDY_TITLE,STUDY_ABSTRACT,IS_PRIMARY\nTest,,YES\n",
        )
        studies = common.load_input_file(
            str(csvfile), json_record_keys=_JSON_RECORD_KEYS,
        )
        assert len(studies) == 1
        assert "STUDY_ABSTRACT" not in studies[0]
        assert studies[0]["STUDY_TITLE"] == "Test"
