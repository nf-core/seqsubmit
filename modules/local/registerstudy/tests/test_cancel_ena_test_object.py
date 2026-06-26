from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import cancel_ena_test_object


def test_build_cancel_xml_targets_accession():
    xml_bytes = cancel_ena_test_object.build_cancel_xml("PRJEB12345")
    root = ET.fromstring(xml_bytes)

    cancel = root.find("./SUBMISSION_SET/SUBMISSION/ACTIONS/ACTION/CANCEL")
    assert cancel is not None
    assert cancel.get("target") == "PRJEB12345"


def test_submit_cancel_parses_success_receipt(monkeypatch):
    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, traceback):
            return False

        def read(self):
            return b'<RECEIPT success="true" />'

    def fake_urlopen(request, timeout):
        assert timeout == 120
        assert request.headers["Content-type"] == "application/xml"
        return FakeResponse()

    monkeypatch.setattr(cancel_ena_test_object.urllib.request, "urlopen", fake_urlopen)

    success, body = cancel_ena_test_object.submit_cancel("PRJEB12345", "Webin-1", "secret")

    assert success
    assert body == '<RECEIPT success="true" />'
