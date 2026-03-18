# nf-core/seqsubmit: Methods

## Overview

`nf-core/seqsubmit` currently contains two workflow implementations:

- `GENOMESUBMIT` for `--mode mags` and `--mode bins`
- `ASSEMBLYSUBMIT` for `--mode metagenomic_assemblies`

This page documents the methods that are currently implemented in the pipeline.

## `GENOMESUBMIT` methods

### Overview

The `GENOMESUBMIT` workflow:

1. Reads the samplesheet and associated genome FASTA files.
2. Validates genome FASTA files.
3. Reuses provided or calculates missing values for RNA genes presence, coverage, taxonomy, and genome quality metrics.
4. Collects genome metadata into the tabular format required by `genome_uploader`.
5. Generates submission manifests for ENA.
6. Performs submission to ENA.

### Genome FASTA validation

Genome FASTA files are validated with the `FASTAVALIDATOR` module before downstream processing. Each file is checked for FASTA format validity and contig count. A genome must contain at least two contigs to pass validation, which is an ENA requirement for contig-level submissions.

Only FASTA files that pass validation are retained for downstream processing and submission.

### RNA presence detection

The workflow only runs internal RNA detection for entries where the `RNA_presence` column is empty. If a value is already supplied in the samplesheet, that value is passed through unchanged.

RNA detection is implemented through the `RNA_DETECTION` subworkflow and combines:

- `barrnap` for rRNA prediction
- `tRNAscan-SE` for tRNA prediction
- the custom `count_rna.py` script for the final decision

#### rRNA detection

`barrnap` is run in bacterial mode (`"bac"`).

The custom parser then scans the GFF output and keeps only the following ribosomal RNA subunits:

- `16S_rRNA`
- `23S_rRNA`
- `5S_rRNA`

For each detected feature, the recovered length is calculated as:

$$
\text{recovered length} = \text{end} - \text{start} + 1
$$

The recovered proportion of each subunit is then estimated relative to the expected reference length used in `count_rna.py`:

- `16S_rRNA`: 1450 bp
- `23S_rRNA`: 2800 bp
- `5S_rRNA`: 115 bp

$$
\text{recovery percent} = \frac{\text{recovered length}}{\text{expected length}} \times 100
$$

If multiple hits are found for the same subunit, the workflow keeps the best recovered percentage for that subunit.

A subunit is considered present when its best recovered percentage is greater than or equal to `--rrna_limit`. The current default is `80`.

#### tRNA detection

`tRNAscan-SE` produces a statistics report that is parsed by `count_rna.py`.

The parser sums the counts assigned to the 20 standard amino-acid isotypes:

- `Ala`, `Arg`, `Asn`, `Asp`, `Cys`
- `Gln`, `Glu`, `Gly`, `His`, `Ile`
- `Leu`, `Lys`, `Met`, `Phe`, `Pro`
- `Ser`, `Thr`, `Trp`, `Tyr`, `Val`

The total number of predicted tRNAs is compared against `params.trna_limit`. The current default is `18`.

#### Final RNA presence decision

The final decision stored in `RNA_presence` is:

- `Yes` when at least 18 tRNAs are detected and all three required rRNA subunits pass the recovery threshold
- `No` otherwise

The result is written as a two-column TSV file containing the genome identifier and the final `Yes`/`No` decision, and this value is then merged back into the submission metadata.

### Genome coverage calculation

Entries that already contain `genome_coverage` are passed through unchanged. For entries where coverage is missing, the workflow joins validated FASTA files with their associated read files and runs `coverm genome` through the `COVERM_GENOME` module (single-end or paired-end mode is selected from sample metadata).

Genome coverage values from `coverm genome` output TSV are parsed and merged into submission metadata.

### Taxonomy assignment

If `NCBI_lineage` is already present in the input samlesheet, the value is retained. If it is missing, the workflow runs taxonomy classification using the `CAT_pack` tool.

Before classification, input FASTA files are normalized to a `.fasta` suffix by `RENAME_FASTA_FOR_CATPACK`. Classification is then run in bin mode (`CAT_pack bins`, followed by `CAT_pack add_names`).

Database input is taken from `--cat_db` when provided; otherwise the workflow uses `--cat_db_download_id` to download and prepare a CATPACK database. The resulting classification table is parsed, and the lineage field is written to `NCBI_lineage`.

### Completeness and contamination assessment

Completeness and contamination are evaluated together in a shared genome quality step.

The workflow checks three samplesheet fields: `completeness`, `contamination`, and `stats_generation_software`. If all three are already present, those values are reused. If any of them is missing, the genome is analysed with `CheckM2 predict`. If `--checkm2_db` is supplied and exists, that database is used directly. Otherwise, the workflow downloads a CheckM2 database from Zenodo (using the configured database ID) and then runs prediction.

For records that run `CheckM2`, completeness and contamination are extracted from the generated quality report (`quality_report.tsv`) and used `CheckM2` version is recorded as `stats_generation_software`.

## `ASSEMBLYSUBMIT` methods

### Overview

The `ASSEMBLYSUBMIT` workflow:

1. Reads the samplesheet and associated assembly FASTA files.
2. Validates assembly FASTA files.
3. Reuses `coverage` values supplied in the samplesheet when they are already present.
4. Calculates `coverage` internally for entries where this field is missing and reads are available.
5. Builds the metadata table used for manifest generation.
6. Generates assembly manifests and submits the assemblies to ENA.

### Assembly FASTA validation

Assembly FASTA files are validated with `FASTAVALIDATOR` before downstream processing. Each file is checked for FASTA format validity and contig count. A genome must contain at least two contigs to pass validation, which is an ENA requirement for contig-level submissions.

Only assemblies with successful validation are forwarded to coverage estimation, metadata/manifest generation and submission.

### Coverage calculation

If the `coverage` column is already populated in the samplesheet, that value is used directly.

If `coverage` is missing, the workflow calculates coverage with `coverm contig`.

`coverm contig` outputs per-contig depth. The workflow then reads this file and calculates the arithmetic mean across all contigs.

If the per-contig coverage values are $c_1, c_2, \ldots, c_n$, the workflow currently computes assembly coverage as an unweighted mean across contigs:

$$
\bar{c} = \frac{1}{n} \sum_{i=1}^{n} c_i
$$
