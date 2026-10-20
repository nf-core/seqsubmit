# nf-core/seqsubmit: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0.1dev - [date]

### `Fixed`

- [#116](https://github.com/nf-core/seqsubmit/pull/116)
  - All tests except the `*_existing_study` ones now register a new submission study, so they can be run with any Webin account ([#95](https://github.com/nf-core/seqsubmit/issues/95)). The `test_mag_complete_metadata_existing_study` and `test_assembly_complete_metadata_existing_study` tests submit to the existing study `PRJEB98843` and require maintainer Webin credentials
  - `test_upload = true` is set explicitly in all test configs
  - Study submission alias now has a random suffix, so parallel registrations started in the same second no longer collide
  - `REGISTERSTUDY` now runs only when at least one input passed validation ([#113](https://github.com/nf-core/seqsubmit/issues/113))
- [#106](https://github.com/nf-core/seqsubmit/pull/106)
  - Added support for metatranscriptome submission for ASSEMBLYSUBMIT
  - Set retry to GENERATE_ASSEMBLY_MANIFEST module
- [#108](https://github.com/nf-core/seqsubmit/pull/108)
  - Added test usecase in test-datasets https://github.com/nf-core/test-datasets/pull/2324 with contamination=0
- [#107](https://github.com/nf-core/seqsubmit/pull/107)
  - Fix `GENOMESUBMIT` treating a zero-valued completeness/contamination as a missing one. The branch that decides whether to (re)compute the statistics with CheckM2 tested the samplesheet values for Groovy truthiness, and the number `0` is falsey

    ```groovy
    genome_evaluation_input: !(meta.completeness) || !(meta.contamination) || !(meta.stats_generation_software)
    ```

    A genome with a legitimate value of `0` — a clean bin with 0% contamination — was therefore sent to `GENOME_EVALUATION`, where the supplied values were silently replaced by the recomputed ones. `stats_generation_software` is rewritten to the tool name reported by the module, so the affected rows also ended up with a different value in that column than the rows that kept their samplesheet statistics.

    The branch now tests for absence, which is what the samplesheet schema expresses: `nf-schema` converts an empty field to `null`, so genuinely missing statistics still route to `GENOME_EVALUATION` while a provided `0` no longer does. This matches the `RNA_presence` test already used in the same workflow.

  - The `genome_coverage` branch (`COVERM_GENOME`) is deliberately unchanged. Its schema field declares `exclusiveMinimum: 0`, so a samplesheet cannot supply `0` there, and an omitted value arrives as `null`, for which the truthiness test and a `null` test behave identically.

### `Dependencies`

### `Deprecated`

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
