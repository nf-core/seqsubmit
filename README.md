<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/nf-core-seqsubmit_logo_dark.png">
    <img alt="nf-core/seqsubmit" src="docs/images/nf-core-seqsubmit_logo_light.png">
  </picture>
</h1>

[![Open in GitHub Codespaces](https://img.shields.io/badge/Open_In_GitHub_Codespaces-black?labelColor=grey&logo=github)](https://github.com/codespaces/new/nf-core/seqsubmit)
[![GitHub Actions CI Status](https://github.com/nf-core/seqsubmit/actions/workflows/nf-test.yml/badge.svg)](https://github.com/nf-core/seqsubmit/actions/workflows/nf-test.yml)
[![GitHub Actions Linting Status](https://github.com/nf-core/seqsubmit/actions/workflows/linting.yml/badge.svg)](https://github.com/nf-core/seqsubmit/actions/workflows/linting.yml)[![AWS CI](https://img.shields.io/badge/CI%20tests-full%20size-FF9900?labelColor=000000&logo=Amazon%20AWS)](https://nf-co.re/seqsubmit/results)[![Cite with Zenodo](http://img.shields.io/badge/DOI-10.5281/zenodo.XXXXXXX-1073c8?labelColor=000000)](https://doi.org/10.5281/zenodo.XXXXXXX)
[![nf-test](https://img.shields.io/badge/unit_tests-nf--test-337ab7.svg)](https://www.nf-test.com)

[![Nextflow](https://img.shields.io/badge/version-%E2%89%A525.04.0-green?style=flat&logo=nextflow&logoColor=white&color=%230DC09D&link=https%3A%2F%2Fnextflow.io)](https://www.nextflow.io/)
[![nf-core template version](https://img.shields.io/badge/nf--core_template-3.5.1-green?style=flat&logo=nfcore&logoColor=white&color=%2324B064&link=https%3A%2F%2Fnf-co.re)](https://github.com/nf-core/tools/releases/tag/3.5.1)
[![run with conda](http://img.shields.io/badge/run%20with-conda-3EB049?labelColor=000000&logo=anaconda)](https://docs.conda.io/en/latest/)
[![run with docker](https://img.shields.io/badge/run%20with-docker-0db7ed?labelColor=000000&logo=docker)](https://www.docker.com/)
[![run with singularity](https://img.shields.io/badge/run%20with-singularity-1d355c.svg?labelColor=000000)](https://sylabs.io/docs/)
[![Launch on Seqera Platform](https://img.shields.io/badge/Launch%20%F0%9F%9A%80-Seqera%20Platform-%234256e7)](https://cloud.seqera.io/launch?pipeline=https://github.com/nf-core/seqsubmit)

[![Get help on Slack](http://img.shields.io/badge/slack-nf--core%20%23seqsubmit-4A154B?labelColor=000000&logo=slack)](https://nfcore.slack.com/channels/seqsubmit)[![Follow on Bluesky](https://img.shields.io/badge/bluesky-%40nf__core-1185fe?labelColor=000000&logo=bluesky)](https://bsky.app/profile/nf-co.re)[![Follow on Mastodon](https://img.shields.io/badge/mastodon-nf__core-6364ff?labelColor=FFFFFF&logo=mastodon)](https://mstdn.science/@nf_core)[![Watch on YouTube](http://img.shields.io/badge/youtube-nf--core-FF0000?labelColor=000000&logo=youtube)](https://www.youtube.com/c/nf-core)

## Introduction

**nf-core/seqsubmit** is a Nextflow pipeline for submitting sequence data to [ENA](https://www.ebi.ac.uk/ena/browser/home).
Currently, the pipeline supports three submission modes, each routed to a dedicated workflow and requiring its own input samplesheet structure:

- `mags` for Metagenome Assembled Genomes (MAGs) submission with `GENOMESUBMIT` workflow
- `bins` for bins submission with `GENOMESUBMIT` workflow
- `metagenomic_assemblies` for assembly submission with `ASSEMBLYSUBMIT` workflow

![seqsubmit workflow diagram](assets/seqsubmit_schema.png)

## Requirements

- [Nextflow](https://www.nextflow.io/) `>=25.04.0`
- Webin account registered at https://www.ebi.ac.uk/ena/submit/webin/login
- Raw reads used to assemble contigs submitted to [INSDC](https://www.insdc.org/) and associated accessions available

Setup your environment secrets before running the pipeline:

`nextflow secrets set WEBIN_ACCOUNT "Webin-XXX"`

`nextflow secrets set WEBIN_PASSWORD "XXX"`

Make sure you update commands above with your authorised credentials.

## Input samplesheets

For detailed descriptions of all samplesheet columns, see the [usage documentation](docs/usage.md#samplesheet-input).

### `mags` and `bins` modes (`GENOMESUBMIT`)

The input must follow `assets/schema_input_genome.json`.

Required columns:

- `sample`
- `fasta` (must end with `.fa.gz` or `.fasta.gz`)
- `accession`
- `assembly_software`
- `binning_software`
- `binning_parameters`
- `stats_generation_software`
- `metagenome`
- `environmental_medium`
- `broad_environment`
- `local_environment`
- `co-assembly`

Columns that required for now, but will be optional in the nearest future:

- `completeness`
- `contamination`
- `genome_coverage`
- `RNA_presence`
- `NCBI_lineage`

Those fields are metadata required for [genome_uploader](https://github.com/EBI-Metagenomics/genome_uploader) package.

Example `samplesheet_genome.csv`:

```csv
sample,fasta,accession,assembly_software,binning_software,binning_parameters,stats_generation_software,completeness,contamination,genome_coverage,metagenome,co-assembly,broad_environment,local_environment,environmental_medium,RNA_presence,NCBI_lineage
lachnospira_eligens,data/bin_lachnospira_eligens.fa.gz,SRR24458089,spades_v3.15.5,metabat2_v2.6,default,CheckM2_v1.0.1,61.0,0.21,32.07,sediment metagenome,No,marine,cable_bacteria,marine_sediment,No,d__Bacteria;p__Proteobacteria;s_unclassified_Proteobacteria
```

### `metagenomic_assemblies` mode (`ASSEMBLYSUBMIT`)

The input must follow `assets/schema_input_assembly.json`.

Required columns:

- `sample`
- `fasta` (must end with `.fa.gz` or `.fasta.gz`)
- `run_accession`
- `assembler`
- `assembler_version`

At least one of the following must be provided per row:

- reads (`fastq_1`, optional `fastq_2` for paired-end)
- `coverage`

If `coverage` is missing and reads are provided, the workflow calculates average coverage with `coverm`.

Example `samplesheet_assembly.csv`:

```csv
sample,fasta,fastq_1,fastq_2,coverage,run_accession,assembler,assembler_version
assembly_1,data/contigs_1.fasta.gz,data/reads_1.fastq.gz,data/reads_2.fastq.gz,,ERR011322,SPAdes,3.15.5
assembly_2,data/contigs_2.fasta.gz,,,42.7,ERR011323,MEGAHIT,1.2.9
```

## Usage

> [!NOTE]
> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow. Make sure to [test your setup](https://nf-co.re/docs/usage/introduction#how-to-run-a-pipeline) with `-profile test` before running the workflow on actual data.

### Required parameters:

| Parameter            | Description                                                                       |
| -------------------- | --------------------------------------------------------------------------------- |
| `--mode`             | Type of the data to be submitted. Options: `[mags, bins, metagenomic_assemblies]` |
| `--input`            | Path to the samplesheet describing the data to be submitted                       |
| `--outdir`           | Path to the output directory for pipeline results                                 |
| `--submission_study` | ENA study accession (PRJ/ERP) to submit the data to                               |
| `--centre_name`      | Name of the submitter's organisation                                              |

### Optional parameters:

| Parameter           | Description                                                                              |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `--upload_tpa`      | Flag to control the type of assembly study (third party assembly or not). Default: false |
| `--test_upload`     | Upload to TEST ENA server instead of LIVE. Default: false                                |
| `--webincli_submit` | If set to false, submissions will be validated, but not submitted. Default: true         |

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

Validation run (submission to the ENA TEST server) in `mags` mode:

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

Validation run (submission to the ENA TEST server) in `metagenomic_assemblies` mode:

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

Live submission example:

```bash
nextflow run nf-core/seqsubmit \
   -profile docker \
   --mode metagenomic_assemblies \
   --input assets/samplesheet_assembly.csv \
   --submission_study PRJEB98843 \
   --test_upload false \
   --webincli_submit true \
   --outdir results/live_assembly
```

> [!WARNING]
> Please provide pipeline parameters via the CLI or Nextflow `-params-file` option. Custom config files including those provided by the `-c` Nextflow option can be used to provide any configuration _**except for parameters**_; see [docs](https://nf-co.re/docs/usage/getting_started/configuration#custom-configuration-files).

For more details and further functionality, please refer to the [usage documentation](https://nf-co.re/seqsubmit/usage) and the [parameter documentation](https://nf-co.re/seqsubmit/parameters).

## Pipeline output

Key output locations in `--outdir`:

- `upload/manifests/`: generated manifest files for submission
- `upload/webin_cli/`: ENA Webin CLI reports
- `multiqc/`: MultiQC summary report
- `pipeline_info/`: execution reports, trace, DAG, and software versions

For full details, see the [output documentation](https://nf-co.re/seqsubmit/output).

## Credits

nf-core/seqsubmit was originally written by [Martin Beracochea](https://github.com/mberacochea), [Ekaterina Sakharova](https://github.com/KateSakharova), [Sofiia Ochkalova](https://github.com/ochkalova), [Evangelos Karatzas](https://github.com/vagkaratzas).

## Contributions and Support

If you would like to contribute to this pipeline, please see the [contributing guidelines](.github/CONTRIBUTING.md).

For further information or help, don't hesitate to get in touch on the [Slack `#seqsubmit` channel](https://nfcore.slack.com/channels/seqsubmit) (you can join with [this invite](https://nf-co.re/join/slack)).

## Citations

<!-- TODO nf-core: Add citation for pipeline after first release. Uncomment lines below and update Zenodo doi and badge at the top of this file. -->

<!-- If you use nf-core/seqsubmit for your analysis, please cite it using the following doi: [10.5281/zenodo.XXXXXX](https://doi.org/10.5281/zenodo.XXXXXX) -->

<!-- TODO nf-core: Add bibliography of tools and data used in your pipeline -->

If you use this pipeline please make sure to cite all used software.
This pipeline uses code and infrastructure developed and maintained by the [nf-core](https://nf-co.re) community, reused here under the [MIT license](https://github.com/nf-core/tools/blob/main/LICENSE).

> **MGnify: the microbiome sequence data analysis resource in 2023**
>
> Richardson L, Allen B, Baldi G, Beracochea M, Bileschi ML, Burdett T, et al.
>
> Vol. 51, Nucleic Acids Research. Oxford University Press (OUP); 2022. p. D753–9. Available from: http://dx.doi.org/10.1093/nar/gkac1080

An extensive list of references for the tools used by the pipeline can be found in the [`CITATIONS.md`](CITATIONS.md) file.

You can cite the `nf-core` publication as follows:

> **The nf-core framework for community-curated bioinformatics pipelines.**
>
> Philip Ewels, Alexander Peltzer, Sven Fillinger, Harshil Patel, Johannes Alneberg, Andreas Wilm, Maxime Ulysse Garcia, Paolo Di Tommaso & Sven Nahnsen.
>
> _Nat Biotechnol._ 2020 Feb 13. doi: [10.1038/s41587-020-0439-x](https://dx.doi.org/10.1038/s41587-020-0439-x).
