# nf-core/seqsubmit: Usage

## :warning: Please read this documentation on the nf-core website: [https://nf-co.re/seqsubmit/usage](https://nf-co.re/seqsubmit/usage)

> _Documentation of pipeline parameters is generated automatically from the pipeline schema and can no longer be found in markdown files._

## Introduction

`nf-core/seqsubmit` is a Nextflow pipeline for submitting metagenomic assemblies, MAGs, and bins to ENA.

The pipeline supports two workflow paths:

- `GENOMESUBMIT` for `--mode mags` and `--mode bins`
- `ASSEMBLYSUBMIT` for `--mode metagenomic_assemblies`

## Before you start

Before running the pipeline, make sure that:

- Nextflow `>=25.04.0` is available.
- You have a Webin account registered at <https://www.ebi.ac.uk/ena/submit/webin/login>.
- The raw reads used to generate the submitted assemblies have already been submitted to INSDC/ENA and the relevant accessions are available.

Set your Webin credentials as Nextflow secrets:

```bash
nextflow secrets set WEBIN_ACCOUNT "Webin-XXX"
nextflow secrets set WEBIN_PASSWORD "XXX"
```

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

| Column                      | Description                                                                                                                                                                                                                                                       |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sample`                    | Unique identifier of this particular data entry. It is used as the alias when submitting to ENA, so it must be unique within one Webin account.                                                                                                                   |
| `fasta`                     | Path to MAG/bin contigs in FASTA format compressed with `gzip`.                                                                                                                                                                                                   |
| `accession`                 | ENA accession of the run or metagenomic assembly used to generate the MAG/bin.                                                                                                                                                                                    |
| `fastq_1`                   | Path to the read file in FASTQ format used to generate the source metagenomic assembly. Required if `genome_coverage` is not provided.                                                                                                                            |
| `fastq_2`                   | Path to the second read file in FASTQ format for paired-end data used to generate the source metagenomic assembly. Leave empty for single-end reads.                                                                                                              |
| `assembly_software`         | Tool name and version that were used to generate the source metagenomic assembly.                                                                                                                                                                                 |
| `binning_software`          | Binning tool, including version, that was used to generate the bins.                                                                                                                                                                                              |
| `binning_parameters`        | Arguments that were used during binning.                                                                                                                                                                                                                          |
| `stats_generation_software` | Tool, including version, that was used to calculate completeness and contamination.                                                                                                                                                                               |
| `completeness`              | Genome completeness value.                                                                                                                                                                                                                                        |
| `contamination`             | Genome contamination value.                                                                                                                                                                                                                                       |
| `genome_coverage`           | Estimated average sequencing depth across the genome. If the value is missing, it is computed automatically during pipeline execution when reads are provided.                                                                                                    |
| `metagenome`                | Registered metagenome taxonomic identifier or name that matches an existing ENA taxonomy entry. For more details see https://ena-docs.readthedocs.io/en/latest/faq/taxonomy.html                                                                                  |
| `co-assembly`               | Whether a co-assembly strategy was used for the initial metagenomic assembly generation. Options: Yes or No.                                                                                                                                                      |
| `broad_environment`         | Broad ecological context of the sample, for example 'marine biome', 'desert biome'. It is recommended to use subclasses of EnvO 'biome' class (http://purl.obolibrary.org/obo/ENVO_00000428)                                                                      |
| `local_environment`         | Local environmental context of the sample, for example 'tropical dry broadleaf forest biome', 'marine abyssal zone biome'. It is recommended to use EnvO terms which are of smaller spatial grain than your entry for "broad-scale environmental context".        |
| `environmental_medium`      | Material displaced by the sample, or the material in which the sample was embedded before sampling, for example 'mucus', 'lake water'. It is recommended to use subclasses of EnvO 'environmental material' class (http://purl.obolibrary.org/obo/ENVO_00010483). |
| `RNA_presence`              | Presence or absence of the 23S, 16S, and 5S rRNA genes and at least 18 tRNAs. This is used for MISAG/MIMAG assembly quality classification. Options: Yes or No.                                                                                                   |
| `NCBI_lineage`              | NCBI taxonomy lineage of the genome. Can be composted of either numerical IDs or taxon names separated by ";".                                                                                                                                                    |

> [!NOTE]
> More information about envioronment tags can be found at checklists [ERC000050](https://www.ebi.ac.uk/ena/browser/view/ERC000050) for bins and [ERC000047](https://www.ebi.ac.uk/ena/browser/view/ERC000047) for MAGs under the field names "broad-scale environmental context", "local environmental context", and "environmental medium".

### `metagenomic_assemblies` mode (`ASSEMBLYSUBMIT`)

Use this samplesheet structure for metagenomic assembly submission. The input format follows [assets/schema_input_assembly.json](../assets/schema_input_assembly.json).

Provide either read files (`fastq_1`, optionally `fastq_2`) or a `coverage` value for each row. If `coverage` is missing and reads are provided, the workflow calculates average coverage automatically.

Example:

```csv title="samplesheet_assembly.csv"
sample,fasta,fastq_1,fastq_2,coverage,run_accession,assembler,assembler_version
assembly_001,data/assembly_001.fasta.gz,data/assembly_001_R1.fastq.gz,data/assembly_001_R2.fastq.gz,,ERR011322,SPAdes,3.15.5
assembly_002,data/assembly_002.fasta.gz,,,42.7,ERR011323,MEGAHIT,1.2.9
```

| Column              | Description                                                                                                                                           |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sample`            | Unique identifier of this particular data entry. It is used as the alias when submitting to ENA, so it must be unique within one Webin account.       |
| `fasta`             | Path to assembly contigs in FASTA format compressed with `gzip`.                                                                                      |
| `fastq_1`           | Path to the read file in FASTQ format used to generate the metagenomic assembly. Required if `coverage` is not provided.                              |
| `fastq_2`           | Path to the second read file in FASTQ format for paired-end data used to generate the source metagenomic assembly. Leave empty for single-end reads.  |
| `coverage`          | Estimated sequencing depth of the assembly. If this value is missing, it is computed automatically during pipeline execution when reads are provided. |
| `run_accession`     | ENA run accession for the reads used to generate the metagenomic assembly. Reads must already be submitted to ENA.                                    |
| `assembler`         | Name of the assembler software used to generate the assembly.                                                                                         |
| `assembler_version` | Version of the assembler software used to generate the assembly.                                                                                      |

An example file is available at [assets/samplesheet_assembly.csv](../assets/samplesheet_assembly.csv).

## Running the pipeline

General command template:

```bash
nextflow run nf-core/seqsubmit \
    -profile <docker/singularity/...> \
    --mode <mags|bins|metagenomic_assemblies> \
    --input <samplesheet.csv> \
    --centre_name <your_centre> \
    --submission_study <your_study> \
    --outdir <outdir>
```

Key parameters:

| Parameter            | Description                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `--mode`             | Submission type. Supported values are `mags`, `bins`, and `metagenomic_assemblies`.                                                  |
| `--input`            | Path to the samplesheet describing the data to submit.                                                                               |
| `--submission_study` | ENA study accession (PRJ/ERP) to submit the data to. For metagenomic assemblies, this is the paper's ENA Assembly Project accession. |
| `--centre_name`      | Name of the submitter's organisation.                                                                                                |
| `--test_upload`      | Submit to the ENA TEST server instead of the LIVE server.                                                                            |
| `--webincli_submit`  | If `true`, submit to ENA. If `false`, validate the submission without uploading.                                                     |
| `--upload_tpa`       | Mark assemblies as third party assemblies when required.                                                                             |

Validation example for `mags` run with docker:

```bash
nextflow run nf-core/seqsubmit \
    -profile docker \
    --mode mags \
    --input assets/samplesheet_genomes.csv \
    --submission_study <your_study> \
    --centre_name TEST_CENTER \
    --webincli_submit true \
    --test_upload true \
    --outdir results/validate_mags
```

Validation example for `metagenomic_assemblies` run with docker:

```bash
nextflow run nf-core/seqsubmit \
    -profile docker \
    --mode metagenomic_assemblies \
    --input assets/samplesheet_assembly.csv \
    --submission_study <your_study> \
    --centre_name TEST_CENTER \
    --webincli_submit true \
    --test_upload true \
    --outdir results/validate_assemblies
```

If you wish to repeatedly use the same parameters for multiple runs, rather than specifying each flag in the command, you can specify these in a params file.

Pipeline settings can be provided in a `yaml` or `json` file via `-params-file <file>`.

> [!WARNING]
> Do not use `-c <file>` to specify parameters as this will result in errors. Custom config files specified with `-c` must only be used for [tuning process resource specifications](https://nf-co.re/docs/usage/configuration#tuning-workflow-resources), other infrastructural tweaks (such as output directories), or module arguments (args).

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

To change the resource requests, please see the [max resources](https://nf-co.re/docs/usage/configuration#max-resources) and [tuning workflow resources](https://nf-co.re/docs/usage/configuration#tuning-workflow-resources) section of the nf-core website.

### Custom Containers

In some cases, you may wish to change the container or conda environment used by a pipeline steps for a particular tool. By default, nf-core pipelines use containers and software from the [biocontainers](https://biocontainers.pro/) or [bioconda](https://bioconda.github.io/) projects. However, in some cases the pipeline specified version maybe out of date.

To use a different container from the default container or conda environment specified in a pipeline, please see the [updating tool versions](https://nf-co.re/docs/usage/configuration#updating-tool-versions) section of the nf-core website.

### Custom Tool Arguments

A pipeline might not always support every possible argument or option of a particular tool used in pipeline. Fortunately, nf-core pipelines provide some freedom to users to insert additional parameters that the pipeline does not include by default.

To learn how to provide additional arguments to a particular tool of the pipeline, please see the [customising tool arguments](https://nf-co.re/docs/usage/configuration#customising-tool-arguments) section of the nf-core website.

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
