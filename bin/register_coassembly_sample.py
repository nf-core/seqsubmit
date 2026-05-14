#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import logging
import os
import xml.etree.ElementTree as ET
import re

import requests
from requests.auth import HTTPBasicAuth
from retry import retry

logger = logging.getLogger("register_coassembly_sample")


RUN_XML_API = "https://www.ebi.ac.uk/ena/browser/api/xml/{accession}"
SAMPLE_XML_API = "https://www.ebi.ac.uk/ena/browser/api/xml/{accession}"
SAMPLE_PORTAL_API = "https://www.ebi.ac.uk/ena/portal/api/search"
CHECKLIST_XML_API = "https://www.ebi.ac.uk/ena/browser/api/xml/ERC000011"

TEST_SUBMIT_URL = "https://wwwdev.ebi.ac.uk/ena/submit/drop-box/submit/"
PROD_SUBMIT_URL = "https://www.ebi.ac.uk/ena/submit/drop-box/submit/"

INSDC_BIOSAMPLE_ACCESSION_REGEX = re.compile(
    r"SAM[AG]?[0-9]+"
)
EXISTING_ACCESSION_IN_ERROR_REGEX = re.compile(
    r'accession:\s*"([A-Z]+[0-9]+)"',
    re.IGNORECASE,
)

DEFAULT_NA_VALUE = "not provided"


class CoassemblyRegistrationError(RuntimeError):
    """Raised for hard validation/submission errors."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Register co-assembly samples.")
    parser.add_argument("--input", required=True, help="Input assembly metadata CSV")
    parser.add_argument("--output", required=True, help="Output assembly metadata CSV")
    parser.add_argument(
        "--test",
        action="store_true",
        help="Register sample using the test submission endpoint",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable verbose debug logging",
    )
    parser.add_argument("--default-country", type=str, help="Default country to use if values differ or are missing.")
    parser.add_argument("--default-date", type=str, help="Default collection date to use if values differ or are missing.")
    parser.add_argument("--default-taxid", type=str, help="Default taxon ID to use if values differ or are missing.")
    parser.add_argument("--default-tax-name", type=str, help="Default taxon name to use if values differ or are missing.")
    return parser.parse_args()


def setup_logging(debug: bool) -> None:
    """Configure logging level and format based on CLI flags."""
    level = logging.DEBUG if debug else logging.INFO
    logging.basicConfig(level=level, format="%(levelname)s: %(message)s", force=True)
    if debug:
        logging.getLogger("requests").setLevel(logging.INFO)
        logging.getLogger("urllib3").setLevel(logging.INFO)
        logging.getLogger("requests.packages.urllib3").setLevel(logging.INFO)
    logger.debug("Debug logging enabled")


def get_credentials() -> tuple[str, str]:
    username = os.environ.get("ENA_WEBIN", "").strip()
    password = os.environ.get("ENA_WEBIN_PASSWORD", "").strip()
    if not username or not password:
        raise CoassemblyRegistrationError(
            "Missing credentials. Set ENA_WEBIN/ENA_WEBIN_PASSWORD."
        )
    return username, password


@retry(tries=3, delay=2, backoff=2)
def get_xml(url: str) -> ET.Element:
    logger.debug(f"Requesting XML URL: {url}")
    response = requests.get(url, timeout=60)
    response.raise_for_status()
    return ET.fromstring(response.content)

@retry(tries=3, delay=2, backoff=2)
def get_json(url: str, params: dict[str, str]) -> list[dict[str, str]]:
    prepared = requests.Request("GET", url, params=params).prepare()
    logger.debug(f"Requesting JSON URL: {prepared.url}")
    response = requests.get(url, params=params, timeout=60)
    response.raise_for_status()
    return response.json()

def to_pretty_xml(root: ET.Element) -> str:
    """Serialize an XML element to a pretty-printed UTF-8 XML string."""
    # Re-parse to avoid side effects from in-place indentation on caller-owned trees.
    normalized_root = ET.fromstring(ET.tostring(root, encoding="utf-8"))
    ET.indent(normalized_root, space="  ")
    return ET.tostring(normalized_root, encoding="utf-8", xml_declaration=True).decode("utf-8")

@retry(tries=3, delay=2, backoff=2)
def submit_sample_xml(auth: HTTPBasicAuth, submit_url: str, sample_xml: str) -> ET.Element:
    submission_xml = """<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<SUBMISSION><ACTIONS><ACTION><ADD/></ACTION></ACTIONS></SUBMISSION>\n"""
    files = {
        "SUBMISSION": ("submission.xml", submission_xml, "application/xml"),
        "SAMPLE": ("sample.xml", sample_xml, "application/xml"),
    }
    response = requests.post(submit_url, files=files, auth=auth, timeout=120)
    response.raise_for_status()
    return ET.fromstring(response.content)

def merge_or_not_provided(values: list[str], default_value=None) -> str:
    """Merge values or return default_value or DEFAULT_NA_VALUE."""
    unique_values = sorted(set(values))
    logger.debug(f"Merging values: {unique_values}")
    if len(unique_values) == 1 and unique_values[0]:
        logger.info(f"Merge decision: using unique value '{unique_values[0]}'")
        return unique_values[0]
    elif default_value:
        logger.info(f"Merge decision: using default value '{default_value}' due to multiple/conflicting values or missing data")
        return default_value
    else:
        logger.info(f"Merge decision: '{DEFAULT_NA_VALUE}' (multiple conflicting values or some missing)")
        return DEFAULT_NA_VALUE

def get_run_sample_from_xml(run_accession: str) -> tuple[str, str | None]:
    """
    Retrieve the sample accession from the RUN XML for a given run accession.

    Args:
        run_accession (str): The run accession to query.

    Returns:
        tuple[str, str | None]: The sample accession and an optional secondary sample accession.

    Raises:
        CoassemblyRegistrationError: If the RUN XML does not contain a sample accession.
    """
    run_root = get_xml(RUN_XML_API.format(accession=run_accession))
    sample_ref = run_root.find(".//RUN_LINKS/RUN_LINK/XREF_LINK[DB='ENA-SAMPLE']/ID")

    if sample_ref is not None and sample_ref.text:
        sample_accession = sample_ref.text.strip()
    else:
        raise CoassemblyRegistrationError(
            f"Run {run_accession} has no sample accession in RUN XML (ENA-SAMPLE link)"
        )

    return sample_accession


def get_sample_metadata(sample_accession: str) -> tuple[str, str, str, str]:
    """
    Retrieve metadata for a given sample accession from the ENA portal.

    Args:
        sample_accession (str): The sample accession to query.

    Returns:
        tuple[str, str, str, str]: A tuple containing tax_id, scientific_name, country, and collection_date.
    """
    if INSDC_BIOSAMPLE_ACCESSION_REGEX.match(sample_accession):
        query = f'"sample_accession={sample_accession}"'
    else:
        query = f'"secondary_sample_accession={sample_accession}"'

    rows = get_json(
        SAMPLE_PORTAL_API,
        params={
            "result": "sample",
            "query": query,
            "fields": "country,collection_date,tax_id,scientific_name",
            "format": "json",
        },
    )

    if not rows:
        logger.warning(f"No portal metadata found for sample {sample_accession}")
        return "", "", "", ""

    row = rows[0]
    return (
        row.get("tax_id"),
        row.get("scientific_name"),
        row.get("country"),
        row.get("collection_date"),
    )

def get_allowed_countries() -> set[str]:
    """
    Retrieve the set of allowed countries from the ENA checklist XML.

    Returns:
        set[str]: A set of allowed country/sea values.
    """
    root = get_xml(CHECKLIST_XML_API)
    values = set()
    field_nodes = root.findall(".//FIELD")
    for field in field_nodes:
        label = field.findtext("LABEL")
        name = field.findtext("NAME")
        if label == "geographic location (country and/or sea)" or name == "geographic_location_country_andor_sea":
            for entry in field.findall(".//TEXT_VALUE/VALUE"):
                if entry.text:
                    values.add(entry.text.strip())
            break
    return values

def build_sample_xml(
    alias: str,
    title: str,
    description: str,
    taxon_id: str,
    scientific_name: str,
    composed_of: str,
    collection_date: str,
    geographic_location: str,
) -> str:
    """
    Build the XML representation of a sample for ENA submission.

    Args:
        alias (str): The sample alias.
        title (str): The sample title.
        description (str): The sample description.
        taxon_id (str): The taxon ID of the sample.
        scientific_name (str): The scientific name of the sample.
        composed_of (str): The list of source samples.
        collection_date (str): The collection date of the sample.
        geographic_location (str): The geographic location of the sample.

    Returns:
        str: The XML string representation of the sample.
    """
    root = ET.Element("SAMPLE_SET")
    sample = ET.SubElement(root, "SAMPLE", {"alias": alias})

    title_node = ET.SubElement(sample, "TITLE")
    title_node.text = title

    sample_name = ET.SubElement(sample, "SAMPLE_NAME")
    taxon = ET.SubElement(sample_name, "TAXON_ID")
    taxon.text = taxon_id
    sci = ET.SubElement(sample_name, "SCIENTIFIC_NAME")
    sci.text = scientific_name

    description_node = ET.SubElement(sample, "DESCRIPTION")
    description_node.text = description

    attrs = ET.SubElement(sample, "SAMPLE_ATTRIBUTES")

    def add_attr(tag: str, value: str) -> None:
        item = ET.SubElement(attrs, "SAMPLE_ATTRIBUTE")
        tag_node = ET.SubElement(item, "TAG")
        tag_node.text = tag
        value_node = ET.SubElement(item, "VALUE")
        value_node.text = value

    add_attr("ENA-CHECKLIST", "ERC000011")
    add_attr("organism", scientific_name)
    add_attr("collection date", collection_date)
    add_attr("composed of", composed_of)
    add_attr("geographic location (country and/or sea)", geographic_location)
    add_attr("scientific_name", scientific_name)

    return to_pretty_xml(root)


def build_virtual_sample_alias(source_samples: list[str], max_length: int = 50) -> str:
    """Build deterministic alias from source samples with an md5 suffix."""
    sorted_samples = sorted(source_samples)
    hash8 = hashlib.md5(",".join(sorted_samples).encode("utf-8")).hexdigest()[:8]

    first_two = sorted_samples[:2]
    remaining = len(sorted_samples) - len(first_two)

    alias_core = f"coassembly_{'_'.join(first_two)}"
    if remaining > 0:
        alias_core = f"{alias_core}_{remaining}_others"

    alias = f"{alias_core}_{hash8}"
    if len(alias) <= max_length:
        return alias

    raise CoassemblyRegistrationError(
        f"Hash suffix '{alias}' exceeds maximum alias length of {max_length}"
    )


def extract_accession_from_receipt(receipt: ET.Element) -> str:
    """
    Extract the sample accession from the ENA submission receipt XML.

    Args:
        receipt (ET.Element): The root element of the receipt XML.

    Returns:
        str: The sample accession.

    Raises:
        CoassemblyRegistrationError: If the receipt does not contain a sample accession.
    """
    success = receipt.attrib.get("success", "false").lower() == "true"
    if not success:
        messages = [m.text for m in receipt.findall(".//MESSAGES/*") if m.text]
        message_text = "; ".join(messages) if messages else "no error details in receipt"

        # If this is a duplicate submission, ENA returns the existing accession.
        existing_match = EXISTING_ACCESSION_IN_ERROR_REGEX.search(message_text)
        if existing_match and "already exists" in message_text.lower():
            existing_accession = existing_match.group(1)
            logger.info(f"Virtual sample already exists; reusing accession: {existing_accession}")
            return existing_accession

        raise CoassemblyRegistrationError(
            f"ENA sample submission failed: {message_text}"
        )

    sample_node = receipt.find(".//SAMPLE")
    if sample_node is not None:
        ena_accession = sample_node.get("accession", "")
        if ena_accession:
            return ena_accession

    raise CoassemblyRegistrationError("ENA sample submission succeeded but no SAMPLE accession found in receipt XML")


def register_virtual_sample(run_accessions: list[str], test: bool, default_country=None, default_date=None, default_taxid=None, default_tax_name=None) -> str:
    """
    Register a virtual sample for co-assemblies based on run accessions.

    Args:
        run_accessions (list[str]): A list of run accessions for the co-assembly.
        test (bool): Whether to use the test submission endpoint.

    Returns:
        str: The sample accession of the registered virtual sample.

    Raises:
        CoassemblyRegistrationError: If validation or submission fails.
    """
    if test:
        submit_url = TEST_SUBMIT_URL
    else:
        submit_url = PROD_SUBMIT_URL

    sample_accessions = []
    taxon_ids = []
    scientific_names = []
    countries = []
    collection_dates = []

    for run in run_accessions:
        sample_acc = get_run_sample_from_xml(run)
        logger.debug(f"Run {run} is linked to sample {sample_acc}")
        sample_accessions.append(sample_acc)

        taxon_id, scientific_name, country, collection_date = get_sample_metadata(sample_acc)
        logger.debug(f"Metadata for sample {sample_acc}: tax_id={taxon_id}, scientific_name={scientific_name}, country={country}, collection_date={collection_date}")
        if not taxon_id:
            raise CoassemblyRegistrationError(f"Sample {sample_acc} has no tax_id in ENA portal response")
        if not scientific_name:
            raise CoassemblyRegistrationError(f"Sample {sample_acc} has no scientific_name in ENA portal response")
        taxon_ids.append(taxon_id)
        scientific_names.append(scientific_name)
        countries.append(country)
        collection_dates.append(collection_date)

    unique_samples = sorted(set(sample_accessions))
    if len(unique_samples) == 1:
        logger.info(f"All source runs belong to one sample ({unique_samples[0]}); keeping original row unchanged")
        return ""

    merged_collection_date = merge_or_not_provided(collection_dates, default_date)
    merged_country = merge_or_not_provided(countries, default_country)
    merged_taxid = merge_or_not_provided(taxon_ids, default_taxid)
    merged_tax_name = merge_or_not_provided(scientific_names, default_tax_name)

    if merged_taxid == DEFAULT_NA_VALUE:
        raise CoassemblyRegistrationError(
            f"Co-assembly source samples have mixed taxa: {', '.join(taxon_ids)}"
        )

    if merged_tax_name == DEFAULT_NA_VALUE:
        raise CoassemblyRegistrationError(
            f"Co-assembly source samples have mixed scientific names: {', '.join(scientific_names)}"
        )

    allowed_countries = get_allowed_countries()
    if merged_country != DEFAULT_NA_VALUE and merged_country not in allowed_countries:
        logger.warning(
            f"Country '{merged_country}' is not in ERC000011 allowed country/sea values; setting to '{DEFAULT_NA_VALUE}'"
        )
        merged_country = DEFAULT_NA_VALUE

    sample_list = ",".join(unique_samples)
    title = f"Combined sample from {sample_list}"
    description = (
        "This sample is a virtual sample of co-assembled raw reads from multiple samples "
        f"of {merged_tax_name}. Co-assembly was performed from runs of the samples {sample_list}"
    )
    alias = build_virtual_sample_alias(unique_samples)
    logger.info(f"Registering virtual sample with alias '{alias}' for co-assembly of samples: {sample_list}")

    sample_xml = build_sample_xml(
        alias=alias,
        title=title,
        description=description,
        taxon_id=merged_taxid,
        scientific_name=merged_tax_name,
        composed_of=sample_list,
        collection_date=merged_collection_date,
        geographic_location=merged_country,
    )

    with open(f"{alias}.xml", "w", encoding="utf-8") as sample_file:
        sample_file.write(sample_xml)

    username, password = get_credentials()
    receipt = submit_sample_xml(HTTPBasicAuth(username, password), submit_url, sample_xml)
    logger.debug(f"ENA receipt XML:\n{ET.tostring(receipt, encoding='unicode')}")
    virtual_sample = extract_accession_from_receipt(receipt)
    logger.info(f"Registered virtual co-assembly sample: {virtual_sample}")
    return virtual_sample


def main() -> int:
    args = parse_args()
    setup_logging(args.debug)

    logger.debug(f"Starting coassembly registration script: input={args.input}, output={args.output}, test={args.test}")

    with open(args.input, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        fieldnames = reader.fieldnames or []
        if "Runs" not in fieldnames:
            raise CoassemblyRegistrationError("Input CSV must have a 'Runs' column with ENA run accessions")
        rows = list(reader)

    # The script may add/update the Sample value; ensure the output schema includes it
    if "Sample" not in fieldnames:
        fieldnames.append("Sample")

    updated_rows: list[dict[str, str]] = []
    for row in rows:
        run_accessions = row["Runs"].split(",")

        logger.info(f"Processing assembly with runs: {run_accessions}")

        # Skip non-coassembly rows by design
        if len(run_accessions) <= 1:
            logger.info("Single run found; skipping coassembly sample registration for this row")
            updated_rows.append(row)
            continue

        virtual_sample = register_virtual_sample(
            run_accessions=run_accessions,
            test=args.test,
            default_country=args.default_country,
            default_date=args.default_date,
            default_taxid=args.default_taxid,
            default_tax_name=args.default_tax_name
        )
        if virtual_sample or virtual_sample == "":
            row["Sample"] = virtual_sample
        updated_rows.append(row)

    logger.info(f"Writing updated assembly metadata to: {args.output}")
    with open(args.output, "w", newline="", encoding="utf-8") as out_handle:
        writer = csv.DictWriter(out_handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(updated_rows)


if __name__ == "__main__":
    main()
