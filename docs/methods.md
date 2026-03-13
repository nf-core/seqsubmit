# nf-core/seqsubmit: Methods

## Overview

`nf-core/seqsubmit` currently contains two workflow implementations:

- `GENOMESUBMIT` for `--mode mags` and `--mode bins`
- `ASSEMBLYSUBMIT` for `--mode metagenomic_assemblies`

This page documents the methods that are currently implemented in the pipeline and includes placeholders for methods that will be documented once they are implemented.

## `GENOMESUBMIT` methods

### Overview

The `GENOMESUBMIT` workflow:

1. Reads the samplesheet and associated genome FASTA files.
2. Reuses `RNA_presence` values supplied in the samplesheet when they are already present.
3. Calculates `RNA_presence` internally for entries where this field is missing.
4. Collects genome metadata into the tabular format required by `genome_upload`.
5. Generates submission manifests for ENA.
6. Performs submission to ENA.

### RNA presence detection

#### When RNA detection runs

The workflow only runs internal RNA detection for entries where the `RNA_presence` column is empty. If a value is already supplied in the samplesheet, that value is passed through unchanged.

#### Tools used

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

A subunit is considered present when its best recovered percentage is greater than or equal to `params.rrna_limit`. The current default is `80`.

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

> [!NOTE]
> Placeholder section.
>
> This section will describe the internal genome coverage calculation once it is implemented in the workflow.
>
> For now, `genome_coverage` is treated as submission metadata.

### Taxonomy assignment

> [!NOTE]
> Placeholder section.
>
> This section will describe the taxonomy assignment method once it is implemented in the workflow.
>
> For now, taxonomy is expected to be provided by the user in the `NCBI_lineage` column.

### Completeness assessment

> [!NOTE]
> Placeholder section.
>
> This section will describe the completeness estimation method once it is implemented in the workflow.
>
> For now, completeness is expected to be provided by the user in the `completeness` column.

### Contamination assessment

> [!NOTE]
> Placeholder section.
>
> This section will describe the contamination estimation method once it is implemented in the workflow.
>
> For now, contamination is expected to be provided by the user in the `contamination` column.

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

Assembly FASTA files are validated with `FASTAVALIDATOR` before downstream processing. Only assemblies that pass validation continue to the coverage and submission steps.

### Coverage calculation

If the `coverage` column is already populated in the samplesheet, that value is used directly.

If `coverage` is missing, the workflow joins each validated assembly with its associated read files and calculates coverage with `coverm contig`.

`coverm contig` outputs per-contig depth. The workflow then reads this file and calculates the arithmetic mean across all contigs.

If the per-contig coverage values are $c_1, c_2, \ldots, c_n$, the workflow currently computes assembly coverage as nweighted mean across contigs:

$$
\bar{c} = \frac{1}{n} \sum_{i=1}^{n} c_i
$$
