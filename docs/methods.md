# nf-core/seqsubmit: Methods

This page provides a detailed overview of the methods and procedures that are executed throughout the nf-core/seqsubmit pipeline.

## `ASSEMBLYSUBMIT`

### Overview

The `ASSEMBLYSUBMIT` workflow:

1. Reads the samplesheet and associated assembly FASTA files.
2. Validates assembly FASTA files.
3. Reuses provided or calculates missing `coverage` values.
4. Builds the metadata table used for manifest generation.
5. Generates assembly manifests and submits the assemblies to ENA.

### Assembly FASTA validation

Assembly FASTA files are validated with `fa-lint` before downstream processing. Each file is checked for FASTA format validity and contig count. A genome must contain at least two contigs to pass validation, which is an ENA requirement for contig-level submissions.

Only assemblies with successful validation are forwarded to coverage estimation, metadata/manifest generation and submission.

### Coverage calculation

If the `coverage` column is already populated in the samplesheet, that value is used directly.

If `coverage` is missing, the workflow calculates coverage with `coverm contig`.

`coverm contig` outputs per-contig depth. The workflow then reads this file and calculates the arithmetic mean across all contigs.

If the per-contig coverage values are $c_1, c_2, \ldots, c_n$, the workflow currently computes assembly coverage as an unweighted mean across contigs:

$$
\bar{c} = \frac{1}{n} \sum_{i=1}^{n} c_i
$$

## `GENOMESUBMIT`

### Overview

The `GENOMESUBMIT` workflow:

1. Reads the samplesheet and associated genome FASTA files.
2. Validates genome FASTA files.
3. Reuses provided or calculates missing values for coverage and taxonomy.
4. Assigns the domain of each genome (bacteria, archaea or eukaryote) from its taxonomy.
5. Reuses provided or calculates missing values for tRNA and rRNA genes presence and genome quality metrics, using domain-specific tools and settings.
6. Collects genome metadata into the tabular format required by `genome_uploader`.
7. Generates submission manifests for ENA.
8. Performs submission to ENA.

### Genome FASTA validation

Genome FASTA files are validated with the `fa-lint` before downstream processing. Each file is checked for FASTA format validity and contig count. A genome must contain at least two contigs to pass validation, which is an ENA requirement for contig-level submissions.

Only FASTA files that pass validation are retained for downstream processing and submission.

### Genome coverage calculation

Entries that already contain `genome_coverage` are passed through unchanged. For entries where coverage is missing, the workflow joins validated FASTA files with their associated read files and runs `coverm genome` through the `COVERM_GENOME` module (single-end or paired-end mode is selected from sample metadata).

Genome coverage values from `coverm genome` output TSV are parsed and merged into submission metadata.

### Taxonomy assignment

If `NCBI_lineage` is already present in the input samplesheet, the value is retained. If it is missing, the workflow runs taxonomy classification using the `CAT_pack` tool.

Before classification, input FASTA files are normalized to a `.fasta` suffix by `RENAME_FASTA_FOR_CATPACK`. Classification is then run in bin mode (`CAT_pack bins`, followed by `CAT_pack add_names`).

Database input is taken from `--cat_db` when provided; otherwise the workflow builds CAT_pack database from NCBI non-redundant protein database (`nr`). See [CAT_pack documentation](https://github.com/MGXlab/CAT_pack#downloading-preconstructed-database-files). There are two options available: `nr` - NCBI non-redundant protein database and `gtdb` (Genome Taxonomy Database (GTDB) proteins). We use NCBI proteins because ENA supports only NCBI format of taxonomy for submission. The resulting classification table is parsed, and the lineage field is written to `NCBI_lineage`.

### Domain assignment

After taxonomy assignment, the workflow decides the domain of each genome from `NCBI_lineage`, which is either provided in the samplesheet or assigned by `CAT_pack`:

- `euk` (eukaryote) if the lineage contains `Eukaryota` or the NCBI taxonomy ID `2759`
- `arc` (archaea) if the lineage contains `Archaea` or the NCBI taxonomy ID `2157`
- `bac` (bacteria) otherwise

The domain defines which tools and settings are used for tRNA and rRNA genes detection and for completeness and contamination assessment.

### tRNA and rRNA genes detection

The workflow only runs tRNA and rRNA genes detection for entries where the `RNA_presence` column is empty. If a value is already supplied in the samplesheet, that value is passed through unchanged.

The resulting `RNA_presence` value is a decisive factor affecting MISAG/MIMAG assembly quality classification of a genome.

tRNA and rRNA genes detection is implemented through the `RNA_DETECTION` subworkflow and combines:

- `barrnap` for rRNA prediction
- `tRNAscan-SE` for tRNA prediction
- the custom `count_rna.py` script for the final decision

All three steps use the domain assigned to the genome (see [Domain assignment](#domain-assignment)).

#### rRNA detection

`barrnap` is run with `--kingdom` matching the domain of the genome: `bac`, `arc` or `euk`.

The custom parser then scans the GFF output and keeps only the rRNA subunits required for the domain:

- bacteria and archaea: `16S_rRNA`, `23S_rRNA`, `5S_rRNA`
- eukaryotes: `18S_rRNA`, `28S_rRNA`, `5_8S_rRNA`, `5S_rRNA`

For each detected feature, the recovered length is calculated as:

$$
\text{recovered length} = \text{end} - \text{start} + 1
$$

The recovered proportion of each subunit is then estimated relative to the expected reference length used in `count_rna.py`:

- `16S_rRNA`: 1450 bp
- `23S_rRNA`: 2800 bp
- `5S_rRNA`: 115 bp
- `18S_rRNA`: 1800 bp
- `28S_rRNA`: 4500 bp
- `5_8S_rRNA`: 155 bp

$$
\text{recovery percent} = \frac{\text{recovered length}}{\text{expected length}} \times 100
$$

If multiple hits are found for the same subunit, the workflow keeps the best recovered percentage for that subunit.

A subunit is considered present when its best recovered percentage is greater than or equal to `--rrna_limit`. The current default is `80`. This threshold is arbitrary, as no strict consensus length is defined by ENA or MISAG/MIMAG for considering an rRNA gene present.

#### tRNA detection

`tRNAscan-SE` is run in the search mode matching the domain of the genome: `-B` (bacteria), `-A` (archaea) or `-E` (eukaryotes). It produces a statistics report that is parsed by `count_rna.py`.

The parser sums the counts assigned to the 20 standard amino-acid isotypes:

- `Ala`, `Arg`, `Asn`, `Asp`, `Cys`
- `Gln`, `Glu`, `Gly`, `His`, `Ile`
- `Leu`, `Lys`, `Met`, `Phe`, `Pro`
- `Ser`, `Thr`, `Trp`, `Tyr`, `Val`

The total number of predicted tRNAs is compared against `params.trna_limit`. The current default is `18`. This value is defined by the MISAG/MIMAG standard and must not be modified.

#### Final `RNA_presence` decision

The final decision stored in `RNA_presence` is:

- `True` when at least 18 tRNAs are detected and all rRNA subunits required for the domain pass the recovery threshold
- `False` otherwise

The final `True`/`False` decision is then merged back into the submission metadata.

### Completeness and contamination assessment

Completeness and contamination are evaluated together in a shared genome quality step implemented in the `GENOME_EVALUATION` subworkflow.

The workflow checks three samplesheet fields: `completeness`, `contamination`, and `stats_generation_software`. If all three are already present, those values are reused. If any of them is missing, the genome is analysed with a tool selected by its domain.

#### Prokaryotes (bacteria and archaea)

Prokaryotic genomes are analysed with `CheckM2 predict`. If `--checkm2_db` is supplied and exists, that database is used directly. Otherwise, the workflow downloads a CheckM2 database from Zenodo (using `--checkm2_db_download_id`) and then runs prediction. The database is downloaded only if there is at least one prokaryotic genome to analyse.

Completeness and contamination are extracted from the generated quality report (`quality_report.tsv`).

#### Eukaryotes

Eukaryotic genomes are analysed with [EukCC](https://github.com/EBI-Metagenomics/EukCC) and, optionally, [BUSCO](https://busco.ezlab.org). The tool used for completeness is set by `--eukaryotic_completeness_tool` (`eukcc` by default). Contamination is always calculated by EukCC.

- `eukcc`: `eukcc single` is run on the uncompressed genome and both completeness and contamination are taken from `eukcc.tsv`.
- `busco`: `BUSCO` is run in `genome` mode with the lineage set by `--busco_db_lineage` (`auto_euk` by default). Completeness is taken from `results` → `Complete percentage` of the BUSCO short summary JSON. With automatic lineage selection, the summary of the selected specific lineage is used. Contamination is taken from EukCC.

If `contamination` is already present in the samplesheet, it is kept. With `busco`, EukCC is then skipped for that genome, as only completeness has to be calculated. With `eukcc`, EukCC still runs to calculate completeness.

The EukCC database (`--eukcc_db`) and BUSCO lineage dataset (`--busco_db`) can be given as a folder or as a `.tar.gz`/`.tgz` archive (local path or URL). Archives are extracted by the pipeline, only if there is at least one eukaryotic genome that needs the tool. If `--busco_db` is not provided, BUSCO downloads the lineage dataset itself.

EukCC exit codes `201` (no marker genes found) and `204` (MetaEuk predicted zero proteins) are not treated as errors: the genome is kept, and its completeness and contamination stay empty. Any other non-zero exit code fails the run. If BUSCO finds no genes and writes no short summary, completeness stays empty.

#### `stats_generation_software`

The tools whose results are used are recorded in `stats_generation_software` as `<tool>_v<version>`, separated by `;`, for example `checkm2_v1.1.0`, `eukcc_v2.2.0` or `busco_v6.1.0;eukcc_v2.2.0`. If `stats_generation_software` is already present in the samplesheet, the tools launched by the pipeline are appended to it, e.g. `CustomTool_v1.0;busco_v6.1.0`.
