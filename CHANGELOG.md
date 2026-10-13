# nf-core/seqsubmit: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0.0 - 01/08/2026

Initial release of nf-core/seqsubmit, created with the [nf-core](https://nf-co.re/) template.

## Added

The pipeline supports four submission modes via dedicated workflows:

- mags — Metagenome Assembled Genomes submission (GENOMESUBMIT)
- bins — Metagenomic bins submission (GENOMESUBMIT)
- metagenomic_assemblies — Assembly submission (ASSEMBLYSUBMIT)
- reads — Raw sequencing reads submission (READSUBMIT)

Key features:

- Automatic study registration with ENA when no existing study accession is provided
- Support for public and private data submissions, including configurable release dates
- Coverage calculation from reads when not provided directly (via coverm)
- Completeness/contamination estimation and taxonomy inference for MAGs/bins (via CheckM2 and CAT_pack) when metadata is incomplete
- Credentials handled securely via Nextflow secrets (ENA_WEBIN, ENA_WEBIN_PASSWORD)
- Full nf-core compatibility: runs with conda, Docker, and Singularity

Authors:

- Sofia Ochkalova
- Ekaterina Sakharova
- Tim Rozday
- Martin Beracochea

Reviewers:

- Evangelos Karatzas
- Martin Beracochea
