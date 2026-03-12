#!/usr/bin/env python3
"""Tests for submit_study.py — ENA study submission pipeline.

Covers:
    A. Unit tests for build_submission_xml and _add_project_element
    B. Unit tests for validate_study_xml
    C. Unit tests for parse_xml_receipt
    D. Unit tests for find_duplicate_studies and fetch_account_studies
    E. CLI integration tests for main() using click.testing.CliRunner

Usage:
    pytest bin/test_submit_study.py -v

All external I/O (HTTP requests, ENA reports API) is mocked. Tests do NOT
import from ena_submit_common directly — all assertions go through the public
API of submit_study.
"""

from __future__ import annotations

import json
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from textwrap import dedent
from typing import Any
from unittest.mock import MagicMock, patch

import pytest
from click.testing import CliRunner
from requests.auth import HTTPBasicAuth

# Ensure the scripts directory is on the path before importing the module.
sys.path.insert(0, os.path.dirname(__file__))

from bin.submit_study import (  # noqa: E402
    _normalize_study_report,
    build_submission_xml,
    fetch_account_studies,
    find_duplicate_studies,
    main,
    parse_xml_receipt,
    validate_study_xml,
)

# ---------------------------------------------------------------------------
# Constants shared across test groups
# ---------------------------------------------------------------------------

_PROD_REPORTS_URL = "https://www.ebi.ac.uk/ena/submit/report/projects"
_TEST_REPORTS_URL = "https://wwwdev.ebi.ac.uk/ena/submit/report/projects"

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def basic_study() -> dict[str, Any]:
    """Return a minimal valid study metadata dict."""
    return {
        "alias": "test-study-001",
        "STUDY_TITLE": "A Basic Test Study",
        "STUDY_ABSTRACT": "An abstract for the test study.",
        "CENTER_PROJECT_NAME": "My Centre Project",
        "existing_study_type": "Metagenomics",
    }


@pytest.fixture
def metagenomics_assembly_study() -> dict[str, Any]:
    """Return a study dict representing a metagenomics assembly submission."""
    return {
        "alias": "metagenome-assembly-001",
        "STUDY_TITLE": "Primary Metagenome Assembly of Soil Sample",
        "STUDY_ABSTRACT": "Assembly of contigs from metagenome sequencing of soil.",
        "CENTER_PROJECT_NAME": "Soil Metagenome Project",
        "existing_study_type": "Metagenomics",
    }


@pytest.fixture
def mag_genome_study() -> dict[str, Any]:
    """Return a study dict representing a MAG/genome submission."""
    return {
        "alias": "mag-genome-001",
        "STUDY_TITLE": "Metagenome-Assembled Genome from Soil Microbiome",
        "STUDY_ABSTRACT": "A high-quality MAG reconstructed from binned metagenome data.",
        "existing_study_type": "Other",
        "new_study_type": "Genome Sequencing",
    }


@pytest.fixture
def mock_credentials() -> tuple[str, str]:
    """Return mock ENA credentials."""
    return ("Webin-12345", "pass")


@pytest.fixture
def auth(mock_credentials: tuple[str, str]) -> HTTPBasicAuth:
    """Return mock HTTPBasicAuth built from mock credentials."""
    return HTTPBasicAuth(*mock_credentials)


@pytest.fixture
def account_study_record() -> dict[str, str]:
    """Return a normalised account study record as returned by the Reports API."""
    return {
        "title": "Existing Study Title",
        "alias": "existing-study-alias",
        "accession": "PRJEB99001",
        "secondary_accession": "ERP099001",
        "status": "PRIVATE",
    }


# ---------------------------------------------------------------------------
# A. Unit tests for build_submission_xml and _add_project_element
# ---------------------------------------------------------------------------


class TestBuildSubmissionXml:
    """Unit tests for build_submission_xml and _add_project_element."""

    # ---- helper -------------------------------------------------------

    @staticmethod
    def _to_str(root: ET.Element) -> str:
        """Serialise an ElementTree element to a UTF-8 string."""
        return ET.tostring(root, encoding="unicode")

    # ---- A1: Basic study fields -------------------------------------------

    def test_study_title_round_trips(self, basic_study: dict[str, Any]) -> None:
        """STUDY_TITLE is written as the TITLE element text."""
        root = build_submission_xml([basic_study])
        title_el = root.find(".//TITLE")
        assert title_el is not None
        assert title_el.text == basic_study["STUDY_TITLE"]

    def test_study_abstract_round_trips(self, basic_study: dict[str, Any]) -> None:
        """STUDY_ABSTRACT is written as the DESCRIPTION element text."""
        root = build_submission_xml([basic_study])
        desc_el = root.find(".//DESCRIPTION")
        assert desc_el is not None
        assert desc_el.text == basic_study["STUDY_ABSTRACT"]

    def test_alias_round_trips(self, basic_study: dict[str, Any]) -> None:
        """The alias attribute on PROJECT matches the input alias."""
        root = build_submission_xml([basic_study])
        project_el = root.find(".//PROJECT")
        assert project_el is not None
        assert project_el.get("alias") == basic_study["alias"]

    def test_center_project_name_round_trips(self, basic_study: dict[str, Any]) -> None:
        """CENTER_PROJECT_NAME is written as the NAME element text."""
        root = build_submission_xml([basic_study])
        name_el = root.find(".//NAME")
        assert name_el is not None
        assert name_el.text == basic_study["CENTER_PROJECT_NAME"]

    def test_submission_project_present(self, basic_study: dict[str, Any]) -> None:
        """SUBMISSION_PROJECT with SEQUENCING_PROJECT is always present."""
        root = build_submission_xml([basic_study])
        sp_el = root.find(".//SUBMISSION_PROJECT")
        assert sp_el is not None
        seq_el = sp_el.find("SEQUENCING_PROJECT")
        assert seq_el is not None

    # ---- A2: Study type PROJECT_ATTRIBUTEs --------------------------------

    def test_existing_study_type_emitted_as_project_attribute(
        self, basic_study: dict[str, Any]
    ) -> None:
        """existing_study_type is emitted as a PROJECT_ATTRIBUTE TAG/VALUE pair."""
        root = build_submission_xml([basic_study])
        xml_str = self._to_str(root)
        assert "existing_study_type" in xml_str
        assert basic_study["existing_study_type"] in xml_str

    def test_new_study_type_absent_when_not_other(self, basic_study: dict[str, Any]) -> None:
        """new_study_type is NOT emitted when existing_study_type != 'Other'."""
        study = dict(basic_study)
        study["new_study_type"] = "Genome Sequencing"
        root = build_submission_xml([study])
        xml_str = self._to_str(root)
        assert "new_study_type" not in xml_str

    def test_new_study_type_present_when_existing_is_other(
        self, mag_genome_study: dict[str, Any]
    ) -> None:
        """new_study_type appears as a PROJECT_ATTRIBUTE when existing_study_type == 'Other'."""
        root = build_submission_xml([mag_genome_study])
        tags = [
            el.text
            for el in root.findall(".//PROJECT_ATTRIBUTE/TAG")
            if el.text is not None
        ]
        values = [
            el.text
            for el in root.findall(".//PROJECT_ATTRIBUTE/VALUE")
            if el.text is not None
        ]
        assert "existing_study_type" in tags
        assert "new_study_type" in tags
        assert "Other" in values
        assert "Genome Sequencing" in values

    def test_no_project_attributes_when_no_study_type(self) -> None:
        """No PROJECT_ATTRIBUTES element when existing_study_type is absent."""
        study = {
            "alias": "no-type",
            "STUDY_TITLE": "No Type Study",
        }
        root = build_submission_xml([study])
        attrs_el = root.find(".//PROJECT_ATTRIBUTES")
        assert attrs_el is None

    # ---- A3: Hold date ----------------------------------------------------

    def test_hold_until_present_in_submission(self, basic_study: dict[str, Any]) -> None:
        """When hold_until is given, HOLD element with HoldUntilDate appears in SUBMISSION."""
        root = build_submission_xml([basic_study], hold_until="2028-06-15")
        hold_el = root.find(".//HOLD")
        assert hold_el is not None
        assert hold_el.get("HoldUntilDate") == "2028-06-15"

    def test_hold_until_absent_when_not_provided(self, basic_study: dict[str, Any]) -> None:
        """When hold_until is not given, no HOLD element appears."""
        root = build_submission_xml([basic_study])
        hold_el = root.find(".//HOLD")
        assert hold_el is None

    # ---- A4: MODIFY action ------------------------------------------------

    def test_modify_action_produces_modify_element(self, basic_study: dict[str, Any]) -> None:
        """Using action='MODIFY' produces a MODIFY element instead of ADD."""
        root = build_submission_xml([basic_study], action="MODIFY")
        xml_str = self._to_str(root)
        assert "<MODIFY" in xml_str or "<MODIFY/>" in xml_str

    def test_add_action_produces_add_element(self, basic_study: dict[str, Any]) -> None:
        """Default action='ADD' produces an ADD element."""
        root = build_submission_xml([basic_study])
        xml_str = self._to_str(root)
        assert "<ADD" in xml_str or "<ADD/>" in xml_str

    def test_modify_action_does_not_produce_add(self, basic_study: dict[str, Any]) -> None:
        """MODIFY action does not produce an ADD element."""
        root = build_submission_xml([basic_study], action="MODIFY")
        xml_str = self._to_str(root)
        # Strip the XML preamble to avoid false positives in attributes
        assert "<ADD" not in xml_str and "<ADD/>" not in xml_str

    # ---- A5: Assembly/metagenomics study ----------------------------------

    def test_metagenomics_assembly_study_round_trips(
        self, metagenomics_assembly_study: dict[str, Any]
    ) -> None:
        """Metagenomics assembly study dict round-trips correctly into XML."""
        root = build_submission_xml([metagenomics_assembly_study])
        project_el = root.find(".//PROJECT")
        assert project_el is not None
        assert project_el.get("alias") == metagenomics_assembly_study["alias"]

        title_el = root.find(".//TITLE")
        assert title_el is not None
        assert title_el.text == metagenomics_assembly_study["STUDY_TITLE"]

        tags = [
            el.text for el in root.findall(".//PROJECT_ATTRIBUTE/TAG") if el.text
        ]
        values = [
            el.text for el in root.findall(".//PROJECT_ATTRIBUTE/VALUE") if el.text
        ]
        assert "existing_study_type" in tags
        assert "Metagenomics" in values

    # ---- A6: MAG/genome study with Other + new_study_type -----------------

    def test_mag_genome_study_has_both_project_attributes(
        self, mag_genome_study: dict[str, Any]
    ) -> None:
        """MAG/genome study with existing_study_type=Other produces both PROJECT_ATTRIBUTEs."""
        root = build_submission_xml([mag_genome_study])
        attr_els = root.findall(".//PROJECT_ATTRIBUTE")
        assert len(attr_els) == 2

        pairs: dict[str, str] = {}
        for attr_el in attr_els:
            tag_el = attr_el.find("TAG")
            val_el = attr_el.find("VALUE")
            if tag_el is not None and val_el is not None:
                pairs[tag_el.text or ""] = val_el.text or ""

        assert pairs.get("existing_study_type") == "Other"
        assert pairs.get("new_study_type") == "Genome Sequencing"

    # ---- Multiple studies in one call -------------------------------------

    def test_multiple_studies_produce_multiple_project_elements(
        self,
        basic_study: dict[str, Any],
        metagenomics_assembly_study: dict[str, Any],
    ) -> None:
        """Multiple studies in input produce multiple PROJECT elements."""
        root = build_submission_xml([basic_study, metagenomics_assembly_study])
        projects = root.findall(".//PROJECT")
        assert len(projects) == 2

    # ---- Alias auto-derived from title when absent ------------------------

    def test_alias_derived_from_title_when_absent(self) -> None:
        """When no alias is provided, alias is derived from STUDY_TITLE (spaces→underscores)."""
        study = {"STUDY_TITLE": "My Derived Title"}
        root = build_submission_xml([study])
        project_el = root.find(".//PROJECT")
        assert project_el is not None
        alias = project_el.get("alias", "")
        assert "_" in alias or alias == "My_Derived_Title"[:50]


# ---------------------------------------------------------------------------
# B. Unit tests for validate_study_xml
# ---------------------------------------------------------------------------


class TestValidateStudyXml:
    """Unit tests for validate_study_xml."""

    @staticmethod
    def _build_valid_xml_bytes(alias: str = "study-1", title: str = "Test Study") -> bytes:
        """Build a minimal valid study XML document as bytes.

        Args:
            alias: The PROJECT alias attribute value.
            title: The TITLE element text.

        Returns:
            UTF-8 encoded XML bytes.
        """
        xml_str = dedent(f"""\
            <?xml version='1.0' encoding='UTF-8'?>
            <WEBIN>
              <PROJECT_SET>
                <PROJECT alias="{alias}">
                  <TITLE>{title}</TITLE>
                  <SUBMISSION_PROJECT>
                    <SEQUENCING_PROJECT/>
                  </SUBMISSION_PROJECT>
                </PROJECT>
              </PROJECT_SET>
            </WEBIN>
        """)
        return xml_str.encode("utf-8")

    # ---- B7: Valid XML passes ---------------------------------------------

    def test_valid_assembly_study_xml_passes(self) -> None:
        """A valid assembly study XML passes validation without errors."""
        xml_bytes = self._build_valid_xml_bytes(
            alias="assembly-study", title="Assembly Study Title"
        )
        is_valid, messages = validate_study_xml(xml_bytes)
        assert is_valid, f"Expected valid; messages: {messages}"

    def test_valid_metagenomics_xml_passes(self) -> None:
        """Well-formed XML with required elements passes validation."""
        study = {
            "alias": "meta-study",
            "STUDY_TITLE": "Metagenomics Study",
            "existing_study_type": "Metagenomics",
        }
        import ena_submit_common as _common  # local import; only for xml_to_bytes helper

        root = build_submission_xml([study])
        xml_bytes = _common.xml_to_bytes(root)
        is_valid, messages = validate_study_xml(xml_bytes)
        assert is_valid, f"Expected valid; messages: {messages}"

    # ---- B8: Missing TITLE ------------------------------------------------

    def test_missing_title_fails_with_title_in_message(self) -> None:
        """A PROJECT without a TITLE element fails validation with 'TITLE' in the message."""
        xml_str = dedent("""\
            <?xml version='1.0' encoding='UTF-8'?>
            <WEBIN>
              <PROJECT_SET>
                <PROJECT alias="no-title">
                  <SUBMISSION_PROJECT><SEQUENCING_PROJECT/></SUBMISSION_PROJECT>
                </PROJECT>
              </PROJECT_SET>
            </WEBIN>
        """)
        is_valid, messages = validate_study_xml(xml_str.encode("utf-8"))
        assert not is_valid
        combined = " ".join(messages)
        assert "TITLE" in combined

    # ---- B9: Missing SUBMISSION_PROJECT -----------------------------------

    def test_missing_submission_project_fails(self) -> None:
        """A PROJECT without SUBMISSION_PROJECT fails with 'SUBMISSION_PROJECT' in message."""
        xml_str = dedent("""\
            <?xml version='1.0' encoding='UTF-8'?>
            <WEBIN>
              <PROJECT_SET>
                <PROJECT alias="no-sp">
                  <TITLE>Some Title</TITLE>
                </PROJECT>
              </PROJECT_SET>
            </WEBIN>
        """)
        is_valid, messages = validate_study_xml(xml_str.encode("utf-8"))
        assert not is_valid
        combined = " ".join(messages)
        assert "SUBMISSION_PROJECT" in combined

    # ---- B10: Malformed XML -----------------------------------------------

    def test_malformed_xml_fails_with_not_well_formed_message(self) -> None:
        """Malformed XML fails validation with 'not well-formed' in the message."""
        bad_xml = b"<WEBIN><PROJECT_SET><PROJECT alias='x'><TITLE>Unclosed"
        is_valid, messages = validate_study_xml(bad_xml)
        assert not is_valid
        combined = " ".join(messages).lower()
        assert "not well-formed" in combined or "well-formed" in combined

    # ---- Extra structural checks -----------------------------------------

    def test_empty_title_fails_validation(self) -> None:
        """A PROJECT with an empty TITLE element fails validation."""
        xml_str = dedent("""\
            <?xml version='1.0' encoding='UTF-8'?>
            <WEBIN>
              <PROJECT_SET>
                <PROJECT alias="empty-title">
                  <TITLE></TITLE>
                  <SUBMISSION_PROJECT><SEQUENCING_PROJECT/></SUBMISSION_PROJECT>
                </PROJECT>
              </PROJECT_SET>
            </WEBIN>
        """)
        is_valid, messages = validate_study_xml(xml_str.encode("utf-8"))
        assert not is_valid

    def test_missing_project_set_fails_validation(self) -> None:
        """XML without a PROJECT_SET element fails validation."""
        xml_str = b"<?xml version='1.0'?><WEBIN/>"
        is_valid, messages = validate_study_xml(xml_str)
        assert not is_valid

    def test_validation_returns_tuple_of_bool_and_list(self) -> None:
        """validate_study_xml always returns (bool, list)."""
        xml_bytes = self._build_valid_xml_bytes()
        result = validate_study_xml(xml_bytes)
        assert isinstance(result, tuple)
        assert len(result) == 2
        is_valid, messages = result
        assert isinstance(is_valid, bool)
        assert isinstance(messages, list)


# ---------------------------------------------------------------------------
# C. Unit tests for parse_xml_receipt
# ---------------------------------------------------------------------------


class TestParseXmlReceipt:
    """Unit tests for parse_xml_receipt."""

    @staticmethod
    def _parse(xml_str: str) -> tuple[bool, list[dict[str, str]], list[str]]:
        """Parse an XML receipt string via parse_xml_receipt.

        Args:
            xml_str: Raw XML receipt string.

        Returns:
            Tuple of (success, accessions, messages).
        """
        root = ET.fromstring(xml_str)
        return parse_xml_receipt(root)

    # ---- C11: Successful PROJECT receipt ----------------------------------

    def test_successful_project_receipt_returns_true(self) -> None:
        """A success='true' receipt returns success=True."""
        xml_str = dedent("""\
            <RECEIPT success="true" receiptDate="2024-01-15T12:00:00.000Z">
              <PROJECT accession="PRJEB12345" alias="my-study"
                       status="PRIVATE" holdUntilDate="2025-01-15">
                <EXT_ID accession="ERP012345" type="study"/>
              </PROJECT>
            </RECEIPT>
        """)
        success, accessions, messages = self._parse(xml_str)
        assert success is True

    def test_successful_project_receipt_accession_round_trips(self) -> None:
        """PROJECT accession, alias, status, holdUntilDate, and external_accession round-trip."""
        xml_str = dedent("""\
            <RECEIPT success="true">
              <PROJECT accession="PRJEB12345" alias="my-study"
                       status="PRIVATE" holdUntilDate="2025-01-15">
                <EXT_ID accession="ERP012345" type="study"/>
              </PROJECT>
            </RECEIPT>
        """)
        success, accessions, messages = self._parse(xml_str)
        assert len(accessions) == 1
        acc = accessions[0]
        assert acc["accession"] == "PRJEB12345"
        assert acc["alias"] == "my-study"
        assert acc["status"] == "PRIVATE"
        assert acc["holdUntilDate"] == "2025-01-15"
        assert acc["external_accession"] == "ERP012345"
        assert acc["external_type"] == "study"

    # ---- C12: Failed receipt ----------------------------------------------

    def test_failed_receipt_returns_false(self) -> None:
        """A success='false' receipt returns success=False."""
        xml_str = dedent("""\
            <RECEIPT success="false">
              <MESSAGES>
                <ERROR>Center name "Unknown" is not permitted to submit in Webin-12345.</ERROR>
              </MESSAGES>
            </RECEIPT>
        """)
        success, accessions, messages = self._parse(xml_str)
        assert success is False

    def test_failed_receipt_captures_error_message(self) -> None:
        """Error text from MESSAGES/ERROR is captured in the messages list."""
        xml_str = dedent("""\
            <RECEIPT success="false">
              <MESSAGES>
                <ERROR>Submission failed due to duplicate alias.</ERROR>
              </MESSAGES>
            </RECEIPT>
        """)
        _, _, messages = self._parse(xml_str)
        assert any("Submission failed due to duplicate alias" in m for m in messages)

    # ---- C13: STUDY tag (alternate ENA format) ----------------------------

    def test_study_tag_receipt_extracts_accession_and_alias(self) -> None:
        """Receipts using STUDY instead of PROJECT still extract accession and alias."""
        xml_str = dedent("""\
            <RECEIPT success="true">
              <STUDY accession="ERP099999" alias="study-alias-1" status="PRIVATE"/>
            </RECEIPT>
        """)
        success, accessions, messages = self._parse(xml_str)
        assert success is True
        assert len(accessions) == 1
        assert accessions[0]["accession"] == "ERP099999"
        assert accessions[0]["alias"] == "study-alias-1"

    # ---- C14: MESSAGES with INFO and ERROR --------------------------------

    def test_receipt_with_info_messages_captured(self) -> None:
        """INFO elements in MESSAGES are captured in the messages list."""
        xml_str = dedent("""\
            <RECEIPT success="true">
              <PROJECT accession="PRJEB00001" alias="x" status="PRIVATE"/>
              <MESSAGES>
                <INFO>Submission processed successfully.</INFO>
              </MESSAGES>
            </RECEIPT>
        """)
        _, _, messages = self._parse(xml_str)
        assert any("Submission processed successfully" in m for m in messages)
        assert any(m.startswith("INFO:") for m in messages)

    def test_receipt_with_multiple_error_messages(self) -> None:
        """Multiple ERROR elements are all captured."""
        xml_str = dedent("""\
            <RECEIPT success="false">
              <MESSAGES>
                <ERROR>First error.</ERROR>
                <ERROR>Second error.</ERROR>
              </MESSAGES>
            </RECEIPT>
        """)
        _, _, messages = self._parse(xml_str)
        error_msgs = [m for m in messages if m.startswith("ERROR:")]
        assert len(error_msgs) == 2

    def test_receipt_both_info_and_error_captured(self) -> None:
        """Both INFO and ERROR elements are captured in messages."""
        xml_str = dedent("""\
            <RECEIPT success="false">
              <MESSAGES>
                <INFO>Partial success.</INFO>
                <ERROR>Some records failed.</ERROR>
              </MESSAGES>
            </RECEIPT>
        """)
        _, _, messages = self._parse(xml_str)
        assert any(m.startswith("INFO:") for m in messages)
        assert any(m.startswith("ERROR:") for m in messages)

    def test_receipt_no_messages_element_returns_empty_list(self) -> None:
        """A receipt without a MESSAGES element returns an empty messages list."""
        xml_str = dedent("""\
            <RECEIPT success="true">
              <PROJECT accession="PRJEB00001" alias="x" status="PRIVATE"/>
            </RECEIPT>
        """)
        _, _, messages = self._parse(xml_str)
        assert messages == []

    def test_receipt_success_false_string(self) -> None:
        """Receipts with success='false' (string) correctly parse to False."""
        xml_str = "<RECEIPT success='false'/>"
        success, _, _ = self._parse(xml_str)
        assert success is False

    def test_receipt_missing_success_defaults_to_false(self) -> None:
        """A receipt without a success attribute defaults to False."""
        xml_str = "<RECEIPT/>"
        success, _, _ = self._parse(xml_str)
        assert success is False


# ---------------------------------------------------------------------------
# D. Unit tests for find_duplicate_studies and fetch_account_studies
# ---------------------------------------------------------------------------


class TestFindDuplicateStudies:
    """Unit tests for find_duplicate_studies."""

    @staticmethod
    def _account_record(
        title: str = "",
        alias: str = "",
        accession: str = "PRJEB00001",
        status: str = "PRIVATE",
    ) -> dict[str, str]:
        """Build a normalised account study record.

        Args:
            title: Study title (as returned by Reports API normalizer).
            alias: Study alias.
            accession: ENA project accession.
            status: Release status.

        Returns:
            Normalised study dict.
        """
        return {
            "title": title,
            "alias": alias,
            "accession": accession,
            "secondary_accession": "",
            "status": status,
        }

    # ---- D15: Exact alias match ------------------------------------------

    def test_exact_alias_match_detected_as_duplicate(self) -> None:
        """An exact alias match is detected as a duplicate."""
        new_studies = [{"STUDY_TITLE": "Different Title", "alias": "my-alias-x"}]
        account = [self._account_record(title="Other", alias="my-alias-x", accession="PRJEB10")]
        dups = find_duplicate_studies(new_studies, account)
        assert 0 in dups
        assert dups[0]["accession"] == "PRJEB10"
        assert "alias" in dups[0]["match_reason"]

    # ---- D16: Exact title match ------------------------------------------

    def test_exact_title_match_detected_as_duplicate(self) -> None:
        """An exact STUDY_TITLE match is detected as a duplicate."""
        new_studies = [{"STUDY_TITLE": "My Metagenomics Study"}]
        account = [
            self._account_record(title="My Metagenomics Study", accession="PRJEB20")
        ]
        dups = find_duplicate_studies(new_studies, account)
        assert 0 in dups
        assert dups[0]["accession"] == "PRJEB20"
        assert "title" in dups[0]["match_reason"]

    # ---- D17: No match returns empty dict --------------------------------

    def test_no_match_returns_empty_dict(self) -> None:
        """When neither alias nor title matches, an empty dict is returned."""
        new_studies = [{"STUDY_TITLE": "Completely Novel Study", "alias": "novel-alias"}]
        account = [self._account_record(title="Existing Study", alias="existing-alias")]
        dups = find_duplicate_studies(new_studies, account)
        assert dups == {}

    def test_empty_account_returns_empty_dict(self) -> None:
        """Empty account list results in no duplicates."""
        new_studies = [{"STUDY_TITLE": "Any Study"}]
        dups = find_duplicate_studies(new_studies, [])
        assert dups == {}

    def test_empty_new_studies_returns_empty_dict(self) -> None:
        """Empty new studies list results in no duplicates."""
        account = [self._account_record(title="Existing")]
        dups = find_duplicate_studies([], account)
        assert dups == {}

    def test_study_without_title_or_alias_not_flagged(self) -> None:
        """A study dict with neither title nor alias is not flagged as duplicate."""
        new_studies = [{"IS_PRIMARY": "YES"}]  # no STUDY_TITLE, no alias
        account = [self._account_record(title="Existing")]
        dups = find_duplicate_studies(new_studies, account)
        assert dups == {}

    def test_partial_title_not_a_duplicate(self) -> None:
        """A partial title match does not count as a duplicate (exact match only)."""
        new_studies = [{"STUDY_TITLE": "Metagenomics"}]
        account = [self._account_record(title="Metagenomics Assembly Study")]
        dups = find_duplicate_studies(new_studies, account)
        assert dups == {}

    def test_multiple_studies_only_matching_flagged(self) -> None:
        """Only the matching study is flagged when multiple new studies are submitted."""
        account = [self._account_record(title="Old Study", alias="old-alias", accession="PRJEB50")]
        new_studies = [
            {"STUDY_TITLE": "Old Study"},
            {"STUDY_TITLE": "New Study"},
        ]
        dups = find_duplicate_studies(new_studies, account)
        assert 0 in dups
        assert 1 not in dups

    def test_duplicate_index_corresponds_to_new_studies_list(self) -> None:
        """The index in the duplicates dict matches the position in new_studies."""
        account = [self._account_record(title="Study C", accession="PRJEB33")]
        new_studies = [
            {"STUDY_TITLE": "Study A"},
            {"STUDY_TITLE": "Study B"},
            {"STUDY_TITLE": "Study C"},
        ]
        dups = find_duplicate_studies(new_studies, account)
        assert 2 in dups
        assert dups[2]["accession"] == "PRJEB33"


# ---------------------------------------------------------------------------
# D18: _normalize_study_report and fetch_account_studies
# ---------------------------------------------------------------------------


class TestNormalizeStudyReport:
    """Unit tests for _normalize_study_report field normalisation."""

    def test_title_field_normalised(self) -> None:
        """The 'title' field is extracted from the raw report dict."""
        report = {"title": "My Title", "alias": "my-alias", "accession": "PRJEB1"}
        result = _normalize_study_report(report)
        assert result["title"] == "My Title"

    def test_study_title_fallback(self) -> None:
        """studyTitle is used when 'title' is absent."""
        report = {"studyTitle": "Study Title Fallback", "alias": "a", "accession": "PRJEB2"}
        result = _normalize_study_report(report)
        assert result["title"] == "Study Title Fallback"

    def test_alias_field_normalised(self) -> None:
        """The 'alias' field is extracted."""
        report = {"title": "T", "alias": "direct-alias", "accession": "PRJEB3"}
        result = _normalize_study_report(report)
        assert result["alias"] == "direct-alias"

    def test_study_alias_fallback(self) -> None:
        """studyAlias is used when 'alias' is absent."""
        report = {"title": "T", "studyAlias": "study-alias-fallback", "accession": "PRJEB4"}
        result = _normalize_study_report(report)
        assert result["alias"] == "study-alias-fallback"

    def test_accession_field_normalised(self) -> None:
        """The 'accession' field is extracted."""
        report = {"title": "T", "alias": "a", "accession": "PRJEB5"}
        result = _normalize_study_report(report)
        assert result["accession"] == "PRJEB5"

    def test_study_accession_fallback(self) -> None:
        """studyAccession is used when 'accession' is absent."""
        report = {"title": "T", "alias": "a", "studyAccession": "PRJEB99"}
        result = _normalize_study_report(report)
        assert result["accession"] == "PRJEB99"

    def test_missing_fields_default_to_empty_string(self) -> None:
        """Missing fields default to empty string without raising."""
        report = {}
        result = _normalize_study_report(report)
        assert result["title"] == ""
        assert result["alias"] == ""
        assert result["accession"] == ""

    def test_status_field_defaults_to_unknown(self) -> None:
        """The status field defaults to 'UNKNOWN' when absent."""
        report = {"title": "T", "alias": "a", "accession": "PRJEB6"}
        result = _normalize_study_report(report)
        assert result["status"] == "UNKNOWN"

    def test_release_status_used_for_status(self) -> None:
        """releaseStatus is mapped to the 'status' key."""
        report = {"title": "T", "alias": "a", "accession": "PRJEB7", "releaseStatus": "PUBLIC"}
        result = _normalize_study_report(report)
        assert result["status"] == "PUBLIC"


class TestFetchAccountStudies:
    """Unit tests for fetch_account_studies calling common.fetch_account_records."""

    def test_fetch_calls_fetch_account_records_with_correct_urls(
        self, auth: HTTPBasicAuth
    ) -> None:
        """fetch_account_studies calls common.fetch_account_records with prod/test URLs."""
        target = "submit_study.common.fetch_account_records"
        with patch(target, return_value=[]) as mock_fetch:
            fetch_account_studies(auth, use_test=False)
            mock_fetch.assert_called_once()
            call_kwargs = mock_fetch.call_args
            assert call_kwargs.kwargs.get("prod_url") == _PROD_REPORTS_URL
            assert call_kwargs.kwargs.get("test_url") == _TEST_REPORTS_URL

    def test_fetch_passes_normalizer_callable(self, auth: HTTPBasicAuth) -> None:
        """fetch_account_studies passes a callable normalizer to fetch_account_records."""
        target = "submit_study.common.fetch_account_records"
        with patch(target, return_value=[]) as mock_fetch:
            fetch_account_studies(auth, use_test=False)
            call_kwargs = mock_fetch.call_args
            normalizer = call_kwargs.kwargs.get("normalizer")
            assert callable(normalizer)

    def test_fetch_normalizer_handles_title_variant(self, auth: HTTPBasicAuth) -> None:
        """The normalizer passed to fetch_account_records handles title/studyTitle variants."""
        target = "submit_study.common.fetch_account_records"
        captured_normalizer = None

        def capture_normalizer(*args: Any, **kwargs: Any) -> list[dict[str, str]]:
            nonlocal captured_normalizer
            captured_normalizer = kwargs.get("normalizer")
            return []

        with patch(target, side_effect=capture_normalizer):
            fetch_account_studies(auth, use_test=False)

        assert captured_normalizer is not None
        result_title = captured_normalizer({"title": "Direct Title", "accession": "PRJEB1"})
        assert result_title["title"] == "Direct Title"

        result_study_title = captured_normalizer(
            {"studyTitle": "Fallback Title", "accession": "PRJEB2"}
        )
        assert result_study_title["title"] == "Fallback Title"

    def test_fetch_normalizer_handles_alias_variant(self, auth: HTTPBasicAuth) -> None:
        """The normalizer handles alias/studyAlias field variants."""
        target = "submit_study.common.fetch_account_records"
        captured_normalizer = None

        def capture_normalizer(*args: Any, **kwargs: Any) -> list[dict[str, str]]:
            nonlocal captured_normalizer
            captured_normalizer = kwargs.get("normalizer")
            return []

        with patch(target, side_effect=capture_normalizer):
            fetch_account_studies(auth, use_test=False)

        assert captured_normalizer is not None
        result = captured_normalizer({"alias": "direct-alias", "accession": "PRJEB3"})
        assert result["alias"] == "direct-alias"

        result_fallback = captured_normalizer(
            {"studyAlias": "study-alias-fallback", "accession": "PRJEB4"}
        )
        assert result_fallback["alias"] == "study-alias-fallback"

    def test_fetch_normalizer_handles_accession_variant(self, auth: HTTPBasicAuth) -> None:
        """The normalizer handles accession/studyAccession field variants."""
        target = "submit_study.common.fetch_account_records"
        captured_normalizer = None

        def capture_normalizer(*args: Any, **kwargs: Any) -> list[dict[str, str]]:
            nonlocal captured_normalizer
            captured_normalizer = kwargs.get("normalizer")
            return []

        with patch(target, side_effect=capture_normalizer):
            fetch_account_studies(auth, use_test=False)

        assert captured_normalizer is not None
        result = captured_normalizer(
            {"title": "T", "studyAccession": "PRJEB99", "accession": ""}
        )
        # studyAccession falls back when 'accession' is falsy
        assert result["accession"] == "PRJEB99"


# ---------------------------------------------------------------------------
# E. CLI integration tests for main() using click.testing.CliRunner
# ---------------------------------------------------------------------------


def _extract_json_from_output(output: str) -> dict[str, Any]:
    """Extract the JSON results dict from mixed CLI output.

    The CLI writes JSON results via ``print()`` to stdout, but logging
    also emits to stderr which CliRunner captures in ``result.output``.
    This helper finds the last top-level JSON object in the output.

    Args:
        output: The full ``result.output`` string from CliRunner.

    Returns:
        Parsed JSON dict.

    Raises:
        ValueError: If no valid JSON object is found.
    """
    # Walk backwards through the output looking for a complete JSON block.
    # The results JSON always starts with "{\n  " and ends with "\n}".
    depth = 0
    end = -1
    start = -1
    for i in range(len(output) - 1, -1, -1):
        ch = output[i]
        if ch == "}":
            if depth == 0:
                end = i
            depth += 1
        elif ch == "{":
            depth -= 1
            if depth == 0:
                start = i
                break
    if start == -1 or end == -1:
        raise ValueError(f"No JSON object found in output: {output[:200]!r}")
    return json.loads(output[start : end + 1])


def _make_study_json(study: dict[str, Any]) -> str:
    """Serialise a study dict into a JSON string using the Container format.

    Args:
        study: Study metadata dict.

    Returns:
        JSON string in DataHarmonizer Container format.
    """
    return json.dumps({
        "Container": {
            "SRA_studys": [study],
        }
    })


def _make_study_csv(study: dict[str, Any]) -> str:
    """Serialise a study dict into a minimal CSV string.

    Args:
        study: Study metadata dict.

    Returns:
        CSV string with header and one data row.
    """
    headers = list(study.keys())
    values = [str(study[h]) for h in headers]
    return ",".join(headers) + "\n" + ",".join(values) + "\n"


def _make_study_tsv(study: dict[str, Any]) -> str:
    """Serialise a study dict into a minimal TSV string.

    Args:
        study: Study metadata dict.

    Returns:
        TSV string with header and one data row.
    """
    headers = list(study.keys())
    values = [str(study[h]) for h in headers]
    return "\t".join(headers) + "\n" + "\t".join(values) + "\n"


@pytest.fixture
def runner() -> CliRunner:
    """Return a Click test runner with isolated filesystem."""
    return CliRunner()


@pytest.fixture
def minimal_metagenomics_study() -> dict[str, Any]:
    """Return a minimal metagenomics study for CLI tests."""
    return {
        "alias": "cli-metagenomics-001",
        "STUDY_TITLE": "CLI Metagenomics Test Study",
        "STUDY_ABSTRACT": "Abstract for CLI test.",
        "existing_study_type": "Metagenomics",
    }


class TestMainCli:
    """CLI integration tests for main() using CliRunner."""

    _CRED_TARGET = "submit_study.common.get_credentials"
    _SUBMIT_TARGET = "submit_study.common.submit_xml"

    def _invoke(
        self,
        runner: CliRunner,
        args: list[str],
        input_filename: str,
        input_content: str,
    ) -> Any:
        """Write input file and invoke the CLI.

        Args:
            runner: Click CliRunner instance.
            args: CLI arguments (excluding --input, which is added automatically).
            input_filename: Filename for the temporary input file.
            input_content: Content to write to the input file.

        Returns:
            Click Result object.
        """
        with runner.isolated_filesystem():
            Path(input_filename).write_text(input_content)
            result = runner.invoke(
                main,
                ["--input", input_filename] + args,
                catch_exceptions=False,
            )
        return result

    # ---- E19: JSON input, automated mode, dry-run -------------------------

    def test_json_input_automated_dry_run_exits_0(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """JSON input with --automated --dry-run exits 0 and output has 'submitted' key."""
        content = _make_study_json(minimal_metagenomics_study)
        with patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")):
            result = self._invoke(
                runner, ["--automated", "--dry-run"], "studies.json", content
            )
        assert result.exit_code == 0, f"stdout: {result.output}"
        data = _extract_json_from_output(result.output)
        assert "submitted" in data

    # ---- E20: CSV input ---------------------------------------------------

    def test_csv_input_automated_dry_run_exits_0(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """CSV input with --automated --dry-run exits 0 and output has 'submitted' key."""
        content = _make_study_csv(minimal_metagenomics_study)
        with patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")):
            result = self._invoke(
                runner, ["--automated", "--dry-run"], "studies.csv", content
            )
        assert result.exit_code == 0, f"stdout: {result.output}"
        data = _extract_json_from_output(result.output)
        assert "submitted" in data

    # ---- E21: TSV input ---------------------------------------------------

    def test_tsv_input_automated_dry_run_exits_0(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """TSV input with --automated --dry-run exits 0 and output has 'submitted' key."""
        content = _make_study_tsv(minimal_metagenomics_study)
        with patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")):
            result = self._invoke(
                runner, ["--automated", "--dry-run"], "studies.tsv", content
            )
        assert result.exit_code == 0, f"stdout: {result.output}"
        data = _extract_json_from_output(result.output)
        assert "submitted" in data

    # ---- E22: Duplicate detection -----------------------------------------

    def test_duplicate_detection_records_duplicate_and_skips_submission(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """When account already has a matching study, duplicate is recorded; nothing submitted."""
        existing = {
            "title": minimal_metagenomics_study["STUDY_TITLE"],
            "alias": minimal_metagenomics_study["alias"],
            "accession": "PRJEB55555",
            "secondary_accession": "ERP055555",
            "status": "PRIVATE",
        }
        content = _make_study_json(minimal_metagenomics_study)
        with runner.isolated_filesystem():
            Path("studies.json").write_text(content)
            with (
                patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")),
                patch(
                    "submit_study.fetch_account_studies",
                    return_value=[existing],
                ),
            ):
                result = runner.invoke(
                    main,
                    ["--input", "studies.json"],
                    catch_exceptions=False,
                )
        assert result.exit_code == 0, f"stdout: {result.output}"
        data = _extract_json_from_output(result.output)
        assert len(data["duplicates"]) == 1
        assert data["duplicates"][0]["existing_accession"] == "PRJEB55555"
        assert data["submitted"] == []

    # ---- E23: --force with duplicate triggers MODIFY ----------------------

    def test_force_flag_with_duplicate_triggers_modify(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """--force with a detected duplicate triggers MODIFY and study appears in 'modified'."""
        existing = {
            "title": minimal_metagenomics_study["STUDY_TITLE"],
            "alias": minimal_metagenomics_study["alias"],
            "accession": "PRJEB66666",
            "secondary_accession": "ERP066666",
            "status": "PRIVATE",
        }
        receipt_xml = ET.fromstring(
            '<RECEIPT success="true">'
            '<PROJECT accession="PRJEB66666" alias="cli-metagenomics-001" status="PRIVATE"/>'
            "</RECEIPT>"
        )
        content = _make_study_json(minimal_metagenomics_study)
        with runner.isolated_filesystem():
            Path("studies.json").write_text(content)
            with (
                patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")),
                patch(
                    "submit_study.fetch_account_studies",
                    return_value=[existing],
                ),
                patch(self._SUBMIT_TARGET, return_value=receipt_xml),
            ):
                result = runner.invoke(
                    main,
                    ["--input", "studies.json", "--force"],
                    catch_exceptions=False,
                )
        assert result.exit_code == 0, f"stdout: {result.output}"
        data = _extract_json_from_output(result.output)
        assert len(data["modified"]) == 1
        assert data["modified"][0]["accession"] == "PRJEB66666"

    # ---- E24: Failed submission exits 1 -----------------------------------

    def test_failed_submission_exits_1(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """When common.submit_xml raises HTTPError, the CLI exits with code 1."""
        import requests

        content = _make_study_json(minimal_metagenomics_study)
        http_error = requests.exceptions.HTTPError(response=MagicMock(status_code=500, text="err"))
        with runner.isolated_filesystem():
            Path("studies.json").write_text(content)
            with (
                patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")),
                patch(self._SUBMIT_TARGET, side_effect=http_error),
            ):
                result = runner.invoke(
                    main,
                    ["--input", "studies.json", "--automated"],
                    catch_exceptions=False,
                )
        assert result.exit_code == 1

    # ---- E25: MAG/genome study dry-run XML contains both PROJECT_ATTRIBUTEs ---

    def test_mag_genome_study_dry_run_xml_has_both_attributes(
        self,
        runner: CliRunner,
    ) -> None:
        """MAG/genome study with existing_study_type=Other produces both PROJECT_ATTRIBUTEs."""
        study = {
            "alias": "mag-001",
            "STUDY_TITLE": "MAG Genome Study",
            "existing_study_type": "Other",
            "new_study_type": "Genome Sequencing",
        }
        content = _make_study_json(study)
        with runner.isolated_filesystem():
            Path("studies.json").write_text(content)
            with patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")):
                result = runner.invoke(
                    main,
                    ["--input", "studies.json", "--automated", "--dry-run"],
                    catch_exceptions=False,
                )
        assert result.exit_code == 0, f"output: {result.output}"
        data = _extract_json_from_output(result.output)
        assert "submitted" in data
        # Also verify the XML would contain both attributes by building it directly
        root = build_submission_xml([study])
        tags = [el.text for el in root.findall(".//PROJECT_ATTRIBUTE/TAG") if el.text]
        assert "existing_study_type" in tags
        assert "new_study_type" in tags

    # ---- E26: --hold-until date present in XML ----------------------------

    def test_hold_until_date_appears_in_submission_xml(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """--hold-until date is present in the HOLD element of the generated XML."""
        study = dict(minimal_metagenomics_study)
        root = build_submission_xml([study], hold_until="2027-12-31")
        hold_el = root.find(".//HOLD")
        assert hold_el is not None
        assert hold_el.get("HoldUntilDate") == "2027-12-31"

    def test_hold_until_cli_flag_passes_validation(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """CLI --hold-until with a valid future date exits 0 in dry-run mode."""
        content = _make_study_json(minimal_metagenomics_study)
        with patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")):
            result = self._invoke(
                runner,
                ["--automated", "--dry-run", "--hold-until", "2027-06-01"],
                "studies.json",
                content,
            )
        assert result.exit_code == 0, f"output: {result.output}"

    # ---- E27: --output writes results to file -----------------------------

    def test_output_flag_writes_results_to_file(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """--output flag writes JSON results to a file rather than stdout."""
        content = _make_study_json(minimal_metagenomics_study)
        with runner.isolated_filesystem():
            Path("studies.json").write_text(content)
            with patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")):
                result = runner.invoke(
                    main,
                    ["--input", "studies.json", "--automated", "--dry-run",
                     "--output", "results.json"],
                    catch_exceptions=False,
                )
            assert result.exit_code == 0, f"stdout: {result.output}"
            # With --output, the JSON results go to file, not stdout (stdout has only logging).
            results_path = Path("results.json")
            assert results_path.exists(), "results.json was not created"
            data = json.loads(results_path.read_text())
            assert "submitted" in data

    # ---- E28: --test flag routes to test base URL -------------------------

    def test_test_flag_uses_test_base_url(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """--test flag results in the test base URL being used for submission."""
        receipt_xml = ET.fromstring(
            '<RECEIPT success="true">'
            '<PROJECT accession="PRJEB00001" alias="cli-metagenomics-001" status="PRIVATE"/>'
            "</RECEIPT>"
        )
        content = _make_study_json(minimal_metagenomics_study)
        with runner.isolated_filesystem():
            Path("studies.json").write_text(content)
            with (
                patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")),
                patch(self._SUBMIT_TARGET, return_value=receipt_xml) as mock_submit,
            ):
                result = runner.invoke(
                    main,
                    ["--input", "studies.json", "--automated", "--test"],
                    catch_exceptions=False,
                )
        assert result.exit_code == 0, f"stdout: {result.output}"
        assert mock_submit.called
        called_url = mock_submit.call_args[0][0]
        assert "wwwdev" in called_url, f"Expected test URL; got {called_url}"

    def test_no_test_flag_uses_production_base_url(
        self,
        runner: CliRunner,
        minimal_metagenomics_study: dict[str, Any],
    ) -> None:
        """Without --test flag, the production base URL is used."""
        receipt_xml = ET.fromstring(
            '<RECEIPT success="true">'
            '<PROJECT accession="PRJEB00002" alias="cli-metagenomics-001" status="PRIVATE"/>'
            "</RECEIPT>"
        )
        content = _make_study_json(minimal_metagenomics_study)
        with runner.isolated_filesystem():
            Path("studies.json").write_text(content)
            with (
                patch(self._CRED_TARGET, return_value=("Webin-12345", "pass")),
                patch(self._SUBMIT_TARGET, return_value=receipt_xml) as mock_submit,
            ):
                result = runner.invoke(
                    main,
                    ["--input", "studies.json", "--automated"],
                    catch_exceptions=False,
                )
        assert result.exit_code == 0, f"stdout: {result.output}"
        assert mock_submit.called
        called_url = mock_submit.call_args[0][0]
        assert "wwwdev" not in called_url, f"Expected prod URL; got {called_url}"


# ---------------------------------------------------------------------------
# Parametrized study-type cases
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "study_type,new_type,expect_new_type",
    [
        ("Metagenomics", None, False),
        ("RNASeq", None, False),
        ("Population Genomics", None, False),
        ("Other", "Genome Sequencing", True),
        ("Other", "Transcriptome Analysis", True),
        ("Other", None, False),
    ],
)
def test_project_attribute_new_study_type_conditional(
    study_type: str,
    new_type: str | None,
    expect_new_type: bool,
) -> None:
    """new_study_type attribute appears iff existing_study_type=='Other' and new_type is set.

    Args:
        study_type: Value for existing_study_type.
        new_type: Value for new_study_type (or None).
        expect_new_type: Whether new_study_type should appear in the XML.
    """
    study: dict[str, Any] = {
        "alias": "param-test",
        "STUDY_TITLE": "Parametrized Study",
        "existing_study_type": study_type,
    }
    if new_type is not None:
        study["new_study_type"] = new_type

    root = build_submission_xml([study])
    tags = [el.text for el in root.findall(".//PROJECT_ATTRIBUTE/TAG") if el.text]
    if expect_new_type:
        assert "new_study_type" in tags, (
            f"Expected new_study_type in tags for {study_type!r} / {new_type!r}"
        )
    else:
        assert "new_study_type" not in tags, (
            f"Did not expect new_study_type in tags for {study_type!r} / {new_type!r}"
        )


@pytest.mark.parametrize(
    "hold_until,expect_hold",
    [
        ("2027-03-01", True),
        ("2028-12-31", True),
        (None, False),
    ],
)
def test_hold_until_element_conditional(hold_until: str | None, expect_hold: bool) -> None:
    """HOLD element appears iff hold_until is provided.

    Args:
        hold_until: The hold-until date string, or None.
        expect_hold: Whether the HOLD element should appear.
    """
    study = {"alias": "hold-test", "STUDY_TITLE": "Hold Date Test"}
    root = build_submission_xml([study], hold_until=hold_until)
    hold_el = root.find(".//HOLD")
    if expect_hold:
        assert hold_el is not None
        assert hold_el.get("HoldUntilDate") == hold_until
    else:
        assert hold_el is None


@pytest.mark.parametrize("action", ["ADD", "MODIFY"])
def test_submission_action_element_present(action: str) -> None:
    """The correct action element (ADD or MODIFY) appears in the SUBMISSION.

    Args:
        action: The submission action string.
    """
    study = {"alias": "action-test", "STUDY_TITLE": "Action Test"}
    root = build_submission_xml([study], action=action)
    xml_str = ET.tostring(root, encoding="unicode")
    assert f"<{action}" in xml_str or f"<{action}/>" in xml_str
    opposite = "MODIFY" if action == "ADD" else "ADD"
    assert f"<{opposite}" not in xml_str
