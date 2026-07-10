# nf-core/seqsubmit: Usage

## :warning: Please read this documentation on the nf-core website: [https://nf-co.re/seqsubmit/usage](https://nf-co.re/seqsubmit/usage)

> _Documentation of pipeline parameters is generated automatically from the pipeline schema and can no longer be found in markdown files._

## Table of Contents

- [Introduction](#introduction)
- [Before you start](#before-you-start)
- [Submission study](#submission-study)
- [Samplesheet input](#samplesheet-input)
  - [`mags` and `bins` modes](#mags-and-bins-modes-genomesubmit)
  - [`metagenomic_assemblies` mode](#metagenomic_assemblies-mode-assemblysubmit)
  - [`reads` mode](#reads-mode-readsubmit)
- [Data privacy](#data-privacy)
- [Database preparation (`mags` / `bins` modes)](#database-preparation-mags--bins)
- [Running the pipeline](#running-the-pipeline)
- [Core Nextflow arguments](#core-nextflow-arguments)
- [Custom configuration](#custom-configuration)
- [Running in the background](#running-in-the-background)
- [Nextflow memory requirements](#nextflow-memory-requirements)

## Introduction

`nf-core/seqsubmit` is a Nextflow pipeline for submitting metagenomic assemblies, MAGs, bins, and raw reads to ENA.

The pipeline supports three workflow paths:

- `GENOMESUBMIT` for `--mode mags` and `--mode bins`
- `ASSEMBLYSUBMIT` for `--mode metagenomic_assemblies`
- `READSUBMIT` for `--mode reads`

## Before you start

Before running the pipeline, make sure that:

- Nextflow `>=25.04.0` is available.
- You have a Webin account registered at <https://www.ebi.ac.uk/ena/submit/webin/login>.
- For metagenomic assemblies submission the raw reads used to generate the assemblies have to be submitted to INSDC/ENA to obtain the corresponding run accessions. You can use the pipeline in mode `reads` to perform this.
- For MAGs or bins submission the raw reads only or raw reads and metagenomic assemblies used to generate the MAGs/bins have to be submitted to INSDC/ENA to obtain the corresponding run or assembly accessions. You can use the pipeline in mode `reads` or `metagenomic_assemblies` to perform this.
- For raw reads submission it is required to register source BioSamples and obtain the sample accessions.

Setup Webin credentials as Nextflow secrets before running the pipeline:

`nextflow secrets set ENA_WEBIN "Webin-XXX"`

`nextflow secrets set ENA_WEBIN_PASSWORD "XXX"`

Make sure you update commands above with your authorised credentials.

## Submission study

All data submitted through this pipeline must be associated with an ENA study (project). You have two options:

### Option 1 — Use an existing study

If you already have an ENA study, pass its accession (starting with `PRJ` or `ERP`) via `--submission_study`:

```bash
--submission_study PRJEB12345
```

You can create a study manually via the [Webin Portal](https://www.ebi.ac.uk/ena/submit/webin/login) and then use the assigned accession here.

### Option 2 — Register a new study automatically

Provide a study metadata file via `--study_metadata` and the pipeline will register the study with ENA before submitting your data:

```bash
--study_metadata study_metadata.json
```

The pipeline accepts JSON, CSV, and TSV formats.

#### JSON formats

Single study as a flat object:

```json
{
  "alias": "study-gut-2026",
  "study_title": "Gut microbiome study",
  "study_abstract": "Characterisation of gut microbial communities"
}
```

#### CSV format

```csv
alias,study_title,study_abstract
study-gut-2026,Gut microbiome study,Characterisation of gut microbial communities
```

#### TSV format

```tsv
alias	study_title	study_abstract
study-soil-2026	Soil microbiome study	Survey of soil microbiota
```

#### Study metadata fields

| Field                 | Required | Description                                                                  |
| --------------------- | -------- | ---------------------------------------------------------------------------- |
| `study_title`         | Yes      | Descriptive title of the study.                                              |
| `alias`               | Yes      | Unique project alias within your Webin account. Max length is 50 characters. |
| `study_abstract`      | No       | Free-text abstract describing the study.                                     |
| `study_description`   | No       | Alternative to `study_abstract`.                                             |
| `project_name`        | No       | Project name. Defaults to `study_title`.                                     |
| `existing_study_type` | No       | ENA study type (e.g. `Metagenomics`, `Other`).                               |
| `new_study_type`      | No       | Custom study type. Only used when `existing_study_type` is set to `Other`.   |

## Samplesheet input

You will need to create a samplesheet with information about the data entries you would like to process before running the pipeline. Use `--input` parameter to specify its location. It has to be a comma-separated file with the structure defined by the execution `--mode`.

```bash
--input '[path to samplesheet.csv]'
```

### `mags` and `bins` modes (`GENOMESUBMIT`)

Use this samplesheet structure for MAG and bin submission. The input format follows [assets/schema_input_genome.json](../assets/schema_input_genome.json).

Example:

```csv title="samplesheet_genomes.csv"
sample,fasta,accession,fastq_1,fastq_2,assembly_software,binning_software,binning_parameters,stats_generation_software,completeness,contamination,genome_coverage,metagenome,co-assembly,broad_environment,local_environment,environmental_medium,RNA_presence,NCBI_lineage
mag_001,data/mag_001.fasta.gz,SRR24458089,,,SPAdes 3.15.5,MetaBAT2 2.15,default,CheckM2 1.0.1,92.81,1.09,66.04,sediment metagenome,No,marine,cable bacteria,marine sediment,No,d__Bacteria;p__Proteobacteria;s__
```

> [!IMPORTANT]
> **Samplesheet column requirements**: All columns shown in the example above must be present in your samplesheet, even if some values are empty. Columns must be in exactly the same order as shown.

| Column                      | Required    | Description                                                                                                                                                                                                                                                       |
| --------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sample`                    | Yes         | A unique identifier for this data entry. Must be globally unique within the input dataset (used as `meta.id` throughout the pipeline).                                                                                                                            |
| `fasta`                     | Yes         | Path to MAG/bin contigs in FASTA format compressed with `gzip`. All names of the FASTA files must be unique to prevent pipeline errors.                                                                                                                           |
| `accession`                 | Yes         | ENA accession of the run or metagenomic assembly used to generate the MAG/bin.                                                                                                                                                                                    |
| `fastq_1`                   | Conditional | Path to the read file in FASTQ format used to generate the source metagenomic assembly. Required if `genome_coverage` is not provided.                                                                                                                            |
| `fastq_2`                   | No          | Path to the second read file in FASTQ format for paired-end data used to generate the source metagenomic assembly. Leave empty for single-end reads.                                                                                                              |
| `assembly_software`         | Yes         | Tool name and version that were used to generate the source metagenomic assembly.                                                                                                                                                                                 |
| `binning_software`          | Yes         | Binning tool, including version, that was used to generate the bins.                                                                                                                                                                                              |
| `binning_parameters`        | Yes         | Arguments that were used during binning.                                                                                                                                                                                                                          |
| `stats_generation_software` | No          | Tool, including version, that was used to calculate completeness and contamination.                                                                                                                                                                               |
| `completeness`              | No          | Genome completeness value.                                                                                                                                                                                                                                        |
| `contamination`             | No          | Genome contamination value.                                                                                                                                                                                                                                       |
| `genome_coverage`           | Conditional | Estimated average sequencing depth across the genome. If the value is missing, it is computed automatically during pipeline execution when reads are provided.                                                                                                    |
| `metagenome`                | Yes         | Registered metagenome taxonomic identifier or name that matches an existing ENA taxonomy entry. For more details see https://ena-docs.readthedocs.io/en/latest/faq/taxonomy.html                                                                                  |
| `co-assembly`               | Yes         | Whether a co-assembly strategy was used for the initial metagenomic assembly generation. Options: Yes or No.                                                                                                                                                      |
| `broad_environment`         | Yes         | Broad ecological context of the sample, for example 'marine biome', 'desert biome'. It is recommended to use subclasses of EnvO 'biome' class (http://purl.obolibrary.org/obo/ENVO_00000428)                                                                      |
| `local_environment`         | Yes         | Local environmental context of the sample, for example 'tropical dry broadleaf forest biome', 'marine abyssal zone biome'. It is recommended to use EnvO terms which are of smaller spatial grain than your entry for "broad-scale environmental context".        |
| `environmental_medium`      | Yes         | Material displaced by the sample, or the material in which the sample was embedded before sampling, for example 'mucus', 'lake water'. It is recommended to use subclasses of EnvO 'environmental material' class (http://purl.obolibrary.org/obo/ENVO_00010483). |
| `RNA_presence`              | No          | Presence or absence of the 23S, 16S, and 5S rRNA genes and at least 18 tRNAs. This is used for MISAG/MIMAG assembly quality classification. Options: Yes or No.                                                                                                   |
| `NCBI_lineage`              | No          | NCBI taxonomy lineage of the genome. Can be composted of either numerical IDs or taxon names separated by ";".                                                                                                                                                    |

> [!NOTE]
> More information about envioronment tags can be found at checklists [ERC000050](https://www.ebi.ac.uk/ena/browser/view/ERC000050) for bins and [ERC000047](https://www.ebi.ac.uk/ena/browser/view/ERC000047) for MAGs under the field names "broad-scale environmental context", "local environmental context", and "environmental medium".

If `genome_coverage`, `stats_generation_software`, `completeness`, `contamination`, `RNA_presence`, or `NCBI_lineage` are missing, the workflow can calculate or infer them when the required inputs are available. See the [Methods documentation](docs/methods.md) for more information on how metadata statistics are obtained.

### `metagenomic_assemblies` mode (`ASSEMBLYSUBMIT`)

Use this samplesheet structure for metagenomic assembly submission. The input format follows [assets/schema_input_assembly.json](../assets/schema_input_assembly.json).

Example:

```csv title="samplesheet_assembly.csv"
sample,fasta,fastq_1,fastq_2,coverage,run_accession,assembler,assembler_version
assembly_001,data/assembly_001.fasta.gz,data/assembly_001_R1.fastq.gz,data/assembly_001_R2.fastq.gz,,ERR011322,SPAdes,3.15.5
assembly_002,data/assembly_002.fasta.gz,,,42.7,ERR011323,MEGAHIT,1.2.9
```

> [!IMPORTANT]
> **Samplesheet column requirements**: All columns shown in the example above must be present in your samplesheet, even if some values are empty. Columns must be in exactly the same order as shown.

| Column              | Required    | Description                                                                                                                                           |
| ------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sample`            | Yes         | A unique identifier for this data entry. Must be globally unique within the input dataset (used as `meta.id` throughout the pipeline).                |
| `fasta`             | Yes         | Path to assembly contigs in FASTA format compressed with `gzip`.                                                                                      |
| `fastq_1`           | Conditional | Path to the read file in FASTQ format used to generate the metagenomic assembly. Required if `coverage` is not provided.                              |
| `fastq_2`           | No          | Path to the second read file in FASTQ format for paired-end data used to generate the source metagenomic assembly. Leave empty for single-end reads.  |
| `coverage`          | Conditional | Estimated sequencing depth of the assembly. If this value is missing, it is computed automatically during pipeline execution when reads are provided. |
| `run_accession`     | Yes         | ENA run accession for the reads used to generate the metagenomic assembly. Reads must already be submitted to ENA.                                    |
| `assembler`         | Yes         | Name of the assembler software used to generate the assembly.                                                                                         |
| `assembler_version` | Yes         | Version of the assembler software used to generate the assembly.                                                                                      |

Provide either read files (`fastq_1`, optionally `fastq_2`) or a `coverage` value for each row. If `coverage` is missing and reads are provided, the workflow calculates average coverage with `coverm`. See the [Methods documentation](docs/methods.md) for more information on how coverage is calculated.

### `reads` mode (`READSUBMIT`)

Use this samplesheet structure for raw sequencing reads submission. The input format follows [assets/schema_input_reads.json](../assets/schema_input_reads.json).

Example:

```csv title="samplesheet_reads.csv"
sample,sample_accession,fastq_1,fastq_2,platform,instrument,library_source,library_selection,library_strategy,insert_size,library_name,description
illumina_run_001,SAMEA1234567,data/reads_R1.fastq.gz,data/reads_R2.fastq.gz,ILLUMINA,Illumina HiSeq 2000,GENOMIC,RANDOM,WGS,500,HiSeq_library_001,Illumina sequencing of sample XYZ
pacbio_run_001,SAMEA7654321,data/pacbio_reads.fastq.gz,,PACBIO_SMRT,PacBio Sequel,GENOMIC,RANDOM,WGS,,PacBio_library_002,Long-read sequencing
```

> [!IMPORTANT]
> **Samplesheet column requirements**: All columns shown in the example above must be present in your samplesheet, even if some values are empty. Columns must be in exactly the same order as shown.

| Column              | Required | Description                                                                                                                                                                                                                                                                                                                                                     |
| ------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sample`            | Yes      | Unique identifier of this particular data entry. Used as an experiment name.                                                                                                                                                                                                                                                                                    |
| `sample_accession`  | Yes      | ENA sample accession (starting with SAMEA) of the sample used to generate raw reads.                                                                                                                                                                                                                                                                            |
| `fastq_1`           | Yes      | Path to forward reads in FASTQ format (optionally gzipped).                                                                                                                                                                                                                                                                                                     |
| `fastq_2`           | No       | Path to reverse reads for paired-end data. Leave empty for single-end reads.                                                                                                                                                                                                                                                                                    |
| `platform`          | Yes      | Sequencing platform. Supported values: `ILLUMINA`, `PACBIO_SMRT`, `OXFORD_NANOPORE`, `ION_TORRENT`, `CAPILLARY`, `DNBSEQ`, `ELEMENT`, `GENAPSYS`, `GENEMIND`, `HELICOS`, `LS454`, `BGISEQ`, `ULTIMA`, `VELA_DIAGNOSTICS`. See [ENA documentation](https://ena-docs.readthedocs.io/en/latest/submit/reads/webin-cli.html#metadata-validation) for complete list. |
| `instrument`        | Yes      | Sequencer model, e.g. "Illumina HiSeq 2000", "PacBio Sequel", "MinION".                                                                                                                                                                                                                                                                                         |
| `library_source`    | Yes      | Library source type. Options: `GENOMIC`, `METAGENOMIC`, `TRANSCRIPTOMIC`, `METAGENOMIC SINGLE CELL`, `TRANSCRIPTOMIC SINGLE CELL`, `SYNTHETIC`, `VIRAL RNA`, `OTHER`.                                                                                                                                                                                           |
| `library_selection` | Yes      | Library selection method. Options: `RANDOM`, `PCR`, `RANDOM PCR`, `RT-PCR`, `MF`, `cDNA`, `cDNA_randomPriming`, `cDNA_oligo_dT`, `PolyA`, `Inverse rRNA`, `ChIP`, `MNase`, `DNase`, `Hybrid Selection`, etc. See [ENA documentation](https://ena-docs.readthedocs.io/en/latest/submit/reads/webin-cli.html#metadata-validation) for complete list.              |
| `library_strategy`  | Yes      | Library strategy. Options: `WGS`, `WGA`, `WXS`, `RNA-Seq`, `miRNA-Seq`, `ncRNA-Seq`, `EST`, `Hi-C`, `ATAC-seq`, `WCS`, `RAD-Seq`, `CLONE`, `AMPLICON`, `POOLCLONE`, `etc`. See [ENA documentation](https://ena-docs.readthedocs.io/en/latest/submit/reads/webin-cli.html#metadata-validation) for complete list.                                                |
| `insert_size`       | No       | Fragment/insert size for paired-end reads (e.g., 500 for 500 bp inserts). Leave empty if not applicable.                                                                                                                                                                                                                                                        |
| `library_name`      | No       | Descriptive library name (optional).                                                                                                                                                                                                                                                                                                                            |
| `description`       | No       | Free-text description of the experiment (optional).                                                                                                                                                                                                                                                                                                             |

## Data privacy

You can reference private ENA data if you have access to it via your Webin account (it was submitted previously under your credentials). To use private data accessions in your submission metadata, specify the `--is_private` flag. The pipeline will then use your provided Webin credentials to fetch the required metadata.

You can also control the privacy of your submitted data:

- If you provide an existing study via `--submission_study`, your submission will inherit the same privacy status as that study.
- If no study is provided, the pipeline will register a new one for you. To keep this new study private, you must specify a release date using `--release_date YYYY-MM-DD` (up to 2 years from the current date).

| Example                                                                                                                                                               | Source Data | Submission Visibility | Required Arguments                                     | Result                                                |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------- | ------------------------------------------------------ | ----------------------------------------------------- |
| Assemblies generated from public reads. Assemblies should be public immediately after submission                                                                      | public      | public                | –                                                      | SUCCESS                                               |
| Assemblies generated from public reads. Assemblies should remain private for 1 year after submission                                                                  | public      | private               | `--release_date YYYY-MM-DD` (+1 year)                  | SUCCESS                                               |
| Bins generated from private reads and assemblies. Bins should be public after submission. User **has access** to the reads and assemblies via Webin account           | private     | public                | `--is_private`                                         | SUCCESS                                               |
| Bins generated from private reads and assemblies. Bins should remain private for 2 years after submission. User **has access** via Webin account                      | private     | private               | `--is_private`, `--release_date YYYY-MM-DD` (+2 years) | SUCCESS                                               |
| MAGs generated from private reads and assemblies. MAGs should be public after submission. User **does not have access** to the reads and assemblies via Webin account | private     | public                | –                                                      | ERROR (submission can only reference accessible data) |

## Database preparation (`mags` / `bins`)

The `GENOMESUBMIT` workflow uses `CheckM2` and `CAT_pack` that require specialized databases for completeness/contamination assessment and taxonomy assignment.

You can either provide pre-existing databases or let the pipeline prepare them during execution.

- `CheckM2`:
  - provide the path to local database with `--checkm2_db`, otherwise the pipeline downloads version specified with `--checkm2_db_download_id` (by default `14897628`).

- `CAT_pack`:
  - provide the path to local database (containing `tax/` and `db/` folders or `tar.gz` archive) with `--cat_db`, otherwise the pipeline constructs version specified with `--cat_db_download_id` (by default `nr`).

See [CAT_pack documentation](https://github.com/MGXlab/CAT_pack) and [CheckM2 documentation](https://github.com/chklovski/CheckM2) for more details on usage and creation of databases.

> [!IMPORTANT]
> `CAT_pack` database creation can take significant time.
>
> Reusing an existing database is strongly recommended for repeated runs.
>
> Databases created/downloaded by the pipeline are published under:
> `${params.outdir}/databases/`

## Running the pipeline

General command template:

```bash
nextflow run nf-core/seqsubmit \
    -profile <docker/singularity/...> \
    --mode <mags|bins|metagenomic_assemblies|reads> \
    --input <samplesheet.csv> \
    --centre_name <your_centre> \
    --submission_study <your_study> \
    --outdir <outdir>
```

Key parameters:

| Parameter            | Description                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `--mode`             | Submission type. Supported values are `mags`, `bins`, `metagenomic_assemblies`, and `reads`.                                         |
| `--input`            | Path to the samplesheet describing the data to submit.                                                                               |
| `--submission_study` | ENA study accession (PRJ/ERP) to submit the data to. For metagenomic assemblies, this is the paper's ENA Assembly Project accession. |
| `--centre_name`      | Name of the submitter's organisation.                                                                                                |
| `--test_upload`      | Submit to the ENA TEST server instead of the LIVE server.                                                                            |
| `--webincli_mode`    | Webin-CLI mode for ENA interaction: `submit` uploads data, `validate` performs validation only.                                      |
| `--upload_tpa`       | Mark assemblies as third party assemblies when required.                                                                             |

Test example for `mags` run with docker:

```bash
nextflow run nf-core/seqsubmit \
    -profile docker \
    --mode mags \
    --input assets/samplesheet_genomes.csv \
    --submission_study <your_study> \
    --centre_name TEST_CENTER \
    --webincli_mode submit \
    --test_upload \
    --outdir results/validate_mags
```

Test example for `metagenomic_assemblies` run with docker:

```bash
nextflow run nf-core/seqsubmit \
    -profile docker \
    --mode metagenomic_assemblies \
    --input assets/samplesheet_assembly.csv \
    --submission_study <your_study> \
    --centre_name TEST_CENTER \
    --webincli_mode submit \
    --test_upload \
    --outdir results/validate_assemblies
```

Test example for `reads` run with docker:

```bash
nextflow run nf-core/seqsubmit \
    -profile docker \
    --mode reads \
    --input samplesheet_reads.csv \
    --submission_study <your_study> \
    --webincli_mode submit \
    --test_upload \
    --outdir results/validate_reads
```

If you wish to repeatedly use the same parameters for multiple runs, rather than specifying each flag in the command, you can specify these in a params file.

Pipeline settings can be provided in a `yaml` or `json` file via `-params-file <file>`.

> [!WARNING]
> Do not use `-c <file>` to specify parameters as this will result in errors. Custom config files specified with `-c` must only be used for [tuning process resource specifications](https://nf-co.re/docs/running/run-pipelines#configuring-pipelines), other infrastructural tweaks (such as output directories), or module arguments (args).

The above pipeline run specified with a params file in yaml format:

```bash
nextflow run nf-core/seqsubmit -profile docker -params-file params.yaml
```

with:

```yaml title="params.yaml"
input: './samplesheet.csv'
outdir: './results/'
<...>
```

You can also generate such `YAML`/`JSON` files via [nf-core/launch](https://nf-co.re/launch).

### Updating the pipeline

When you run the above command, Nextflow automatically pulls the pipeline code from GitHub and stores it as a cached version. When running the pipeline after this, it will always use the cached version if available - even if the pipeline has been updated since. To make sure that you're running the latest version of the pipeline, make sure that you regularly update the cached version of the pipeline:

```bash
nextflow pull nf-core/seqsubmit
```

### Reproducibility

It is a good idea to specify the pipeline version when running the pipeline on your data. This ensures that a specific version of the pipeline code and software are used when you run your pipeline. If you keep using the same tag, you'll be running the same version of the pipeline, even if there have been changes to the code since.

First, go to the [nf-core/seqsubmit releases page](https://github.com/nf-core/seqsubmit/releases) and find the latest pipeline version - numeric only (eg. `1.3.1`). Then specify this when running the pipeline with `-r` (one hyphen) - eg. `-r 1.3.1`. Of course, you can switch to another version by changing the number after the `-r` flag.

This version number will be logged in reports when you run the pipeline, so that you'll know what you used when you look back in the future. For example, at the bottom of the MultiQC reports.

To further assist in reproducibility, you can use share and reuse [parameter files](#running-the-pipeline) to repeat pipeline runs with the same settings without having to write out a command with every single parameter.

> [!TIP]
> If you wish to share such profile (such as upload as supplementary material for academic publications), make sure to NOT include cluster specific paths to files, nor institutional specific profiles.

## Core Nextflow arguments

> [!NOTE]
> These options are part of Nextflow and use a _single_ hyphen (pipeline parameters use a double-hyphen)

### `-profile`

Use this parameter to choose a configuration profile. Profiles can give configuration presets for different compute environments.

Several generic profiles are bundled with the pipeline which instruct the pipeline to use software packaged using different methods (Docker, Singularity, Podman, Shifter, Charliecloud, Apptainer, Conda) - see below.

> [!IMPORTANT]
> We highly recommend the use of Docker or Singularity containers for full pipeline reproducibility, however when this is not possible, Conda is also supported.

The pipeline also dynamically loads configurations from [https://github.com/nf-core/configs](https://github.com/nf-core/configs) when it runs, making multiple config profiles for various institutional clusters available at run time. For more information and to check if your system is supported, please see the [nf-core/configs documentation](https://github.com/nf-core/configs#documentation).

Note that multiple profiles can be loaded, for example: `-profile test,docker` - the order of arguments is important!
They are loaded in sequence, so later profiles can overwrite earlier profiles.

If `-profile` is not specified, the pipeline will run locally and expect all software to be installed and available on the `PATH`. This is _not_ recommended, since it can lead to different results on different machines dependent on the computer environment.

- `test`
  - A profile with a complete configuration for automated testing
  - Includes links to test data so needs no other parameters
- `docker`
  - A generic configuration profile to be used with [Docker](https://docker.com/)
- `singularity`
  - A generic configuration profile to be used with [Singularity](https://sylabs.io/docs/)
- `podman`
  - A generic configuration profile to be used with [Podman](https://podman.io/)
- `shifter`
  - A generic configuration profile to be used with [Shifter](https://nersc.gitlab.io/development/shifter/how-to-use/)
- `charliecloud`
  - A generic configuration profile to be used with [Charliecloud](https://charliecloud.io/)
- `apptainer`
  - A generic configuration profile to be used with [Apptainer](https://apptainer.org/)
- `wave`
  - A generic configuration profile to enable [Wave](https://seqera.io/wave/) containers. Use together with one of the above (requires Nextflow ` 24.03.0-edge` or later).
- `conda`
  - A generic configuration profile to be used with [Conda](https://conda.io/docs/). Please only use Conda as a last resort i.e. when it's not possible to run the pipeline with Docker, Singularity, Podman, Shifter, Charliecloud, or Apptainer.

### `-resume`

Specify this when restarting a pipeline. Nextflow will use cached results from any pipeline steps where the inputs are the same, continuing from where it got to previously. For input to be considered the same, not only the names must be identical but the files' contents as well. For more info about this parameter, see [this blog post](https://www.nextflow.io/blog/2019/demystifying-nextflow-resume.html).

You can also supply a run name to resume a specific run: `-resume [run-name]`. Use the `nextflow log` command to show previous run names.

### `-c`

Specify the path to a specific config file (this is a core Nextflow command). See the [nf-core website documentation](https://nf-co.re/usage/configuration) for more information.

## Custom configuration

### Resource requests

Whilst the default requirements set within the pipeline will hopefully work for most people and with most input data, you may find that you want to customise the compute resources that the pipeline requests. Each step in the pipeline has a default set of requirements for number of CPUs, memory and time. For most of the pipeline steps, if the job exits with any of the error codes specified [here](https://github.com/nf-core/rnaseq/blob/4c27ef5610c87db00c3c5a3eed10b1d161abf575/conf/base.config#L18) it will automatically be resubmitted with higher resources request (2 x original, then 3 x original). If it still fails after the third attempt then the pipeline execution is stopped.

To change the resource requests, please see the [max resources](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#set-max-resources) and [customise process resources](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#customize-process-resources) section of the nf-core website.

### Custom Containers

In some cases, you may wish to change the container or conda environment used by a pipeline steps for a particular tool. By default, nf-core pipelines use containers and software from the [biocontainers](https://biocontainers.pro/) or [bioconda](https://bioconda.github.io/) projects. However, in some cases the pipeline specified version maybe out of date.

To use a different container from the default container or conda environment specified in a pipeline, please see the [updating tool versions](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#update-tool-versions) section of the nf-core website.

### Custom Tool Arguments

A pipeline might not always support every possible argument or option of a particular tool used in pipeline. Fortunately, nf-core pipelines provide some freedom to users to insert additional parameters that the pipeline does not include by default.

To learn how to provide additional arguments to a particular tool of the pipeline, please see the [customising tool arguments](https://nf-co.re/docs/running/configuration/nextflow-for-your-system#modifying-tool-arguments) section of the nf-core website.

### nf-core/configs

In most cases, you will only need to create a custom config as a one-off but if you and others within your organisation are likely to be running nf-core pipelines regularly and need to use the same settings regularly it may be a good idea to request that your custom config file is uploaded to the `nf-core/configs` git repository. Before you do this please can you test that the config file works with your pipeline of choice using the `-c` parameter. You can then create a pull request to the `nf-core/configs` repository with the addition of your config file, associated documentation file (see examples in [`nf-core/configs/docs`](https://github.com/nf-core/configs/tree/master/docs)), and amending [`nfcore_custom.config`](https://github.com/nf-core/configs/blob/master/nfcore_custom.config) to include your custom profile.

See the main [Nextflow documentation](https://www.nextflow.io/docs/latest/config.html) for more information about creating your own configuration files.

If you have any questions or issues please send us a message on [Slack](https://nf-co.re/join/slack) on the [`#configs` channel](https://nfcore.slack.com/channels/configs).

## Running in the background

Nextflow handles job submissions and supervises the running jobs. The Nextflow process must run until the pipeline is finished.

The Nextflow `-bg` flag launches Nextflow in the background, detached from your terminal so that the workflow does not stop if you log out of your session. The logs are saved to a file.

Alternatively, you can use `screen` / `tmux` or similar tool to create a detached session which you can log back into at a later time.
Some HPC setups also allow you to run nextflow within a cluster job submitted your job scheduler (from where it submits more jobs).

## Nextflow memory requirements

In some cases, the Nextflow Java virtual machines can start to request a large amount of memory.
We recommend adding the following line to your environment to limit this (typically in `~/.bashrc` or `~./bash_profile`):

```bash
NXF_OPTS='-Xms1g -Xmx4g'
```
