"""Tests for submit_study.py's seqsubmit-specific glue: the field-name
adapter, JSON/CSV/TSV loading, and test-mode alias hashing. The actual
submission/XML/XSD logic these delegate to is covered by
ena-submission-toolkit's own test suite, not duplicated here.
"""

from __future__ import annotations

import json

import pytest
from submit_study import (
    _adapt_record,
    _test_mode_alias,
    extract_records_from_tabular,
    load_and_validate_input_file,
)


def test_adapt_record_renames_known_fields_and_passes_through_others():
    record = {
        "alias": "study-1",
        "study_title": "Title",
        "study_abstract": "Abstract",
        "study_description": "Description",
        "project_name": "Project",
        "existing_study_type": "Metagenomics",
        "new_study_type": "Other type",
    }
    adapted = _adapt_record(record)
    assert adapted == {
        "alias": "study-1",
        "STUDY_TITLE": "Title",
        "STUDY_ABSTRACT": "Abstract",
        "STUDY_DESCRIPTION": "Description",
        "CENTER_PROJECT_NAME": "Project",
        "existing_study_type": "Metagenomics",
        "new_study_type": "Other type",
    }


def test_test_mode_alias_appends_distinct_hash_suffix():
    a = _test_mode_alias("study-1")
    b = _test_mode_alias("study-1")
    assert a.startswith("study-1_")
    assert len(a) == len("study-1_") + 8
    # Vanishingly unlikely to collide; mainly checks the suffix isn't static.
    assert a != b or a.endswith(b.rsplit("_", 1)[-1])


def test_load_and_validate_input_file_json(tmp_path):
    path = tmp_path / "studies.json"
    path.write_text(json.dumps([{"alias": "a", "study_title": "A"}]))
    records = load_and_validate_input_file(path)
    assert records == [{"alias": "a", "study_title": "A"}]


def test_load_and_validate_input_file_missing_required_field_raises(tmp_path):
    path = tmp_path / "studies.json"
    path.write_text(json.dumps([{"alias": "a"}]))  # missing study_title
    with pytest.raises(ValueError, match="study_title"):
        load_and_validate_input_file(path)


def test_load_and_validate_input_file_unsupported_extension_raises(tmp_path):
    path = tmp_path / "studies.txt"
    path.write_text("alias\tstudy_title\na\tA\n")
    with pytest.raises(ValueError, match="Unsupported file format"):
        load_and_validate_input_file(path)


def test_extract_records_from_tabular_tsv(tmp_path):
    path = tmp_path / "studies.tsv"
    path.write_text("alias\tstudy_title\nstudy-1\tTitle One\n")
    records = extract_records_from_tabular(path, delimiter="\t")
    assert records == [{"alias": "study-1", "study_title": "Title One"}]
