#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path


def generate_reads_manifest(
    output_path: Path,
    study: str,
    sample: str,
    name: str,
    platform: str,
    instrument: str,
    library_source: str,
    library_selection: str,
    library_strategy: str,
    fastq_files: list[str],
    insert_size: int | None = None,
    library_name: str | None = None,
    description: str | None = None,
) -> None:
    """Write a tab-delimited ENA reads submission manifest file.

    Appends a timestamp to `name` so re-submitting the same run data
    produces a distinct NAME field and avoids ENA duplicate-rejection errors.
    """
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    run_name = f"{name}_{timestamp}"

    fields: list[tuple[str, str]] = [
        ("STUDY", study),
        ("SAMPLE", sample),
        ("NAME", run_name),
        ("PLATFORM", platform),
        ("INSTRUMENT", instrument),
        ("LIBRARY_SOURCE", library_source),
        ("LIBRARY_SELECTION", library_selection),
        ("LIBRARY_STRATEGY", library_strategy),
    ]

    if insert_size is not None:
        fields.append(("INSERT_SIZE", str(insert_size)))
    if library_name:
        fields.append(("LIBRARY_NAME", library_name))
    if description:
        fields.append(("DESCRIPTION", description))

    for fq in fastq_files:
        fields.append(("FASTQ", fq))

    with output_path.open("w") as fh:
        for key, value in fields:
            fh.write(f"{key}\t{value}\n")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate an ENA reads submission manifest file."
    )
    parser.add_argument("--study", required=True)
    parser.add_argument("--sample", required=True)
    parser.add_argument("--name", required=True,
                        help="Run name base; a YYYYmmddHHMMSS timestamp is appended")
    parser.add_argument("--platform", required=True)
    parser.add_argument("--instrument", required=True)
    parser.add_argument("--library-source", required=True)
    parser.add_argument("--library-selection", required=True)
    parser.add_argument("--library-strategy", required=True)
    parser.add_argument("--fastq", required=True, action="append",
                        dest="fastq_files", metavar="FILE",
                        help="FASTQ file (repeat for paired-end)")
    parser.add_argument("--output", required=True, type=Path,
                        help="Path for the output manifest file")
    parser.add_argument("--insert-size", type=int, default=None)
    parser.add_argument("--library-name", default=None)
    parser.add_argument("--description", default=None)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    generate_reads_manifest(
        output_path=args.output,
        study=args.study,
        sample=args.sample,
        name=args.name,
        platform=args.platform,
        instrument=args.instrument,
        library_source=args.library_source,
        library_selection=args.library_selection,
        library_strategy=args.library_strategy,
        fastq_files=args.fastq_files,
        insert_size=args.insert_size,
        library_name=args.library_name,
        description=args.description,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
