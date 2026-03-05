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

**nf-core/seqsubmit** is a bioinformatics pipeline that submits data to public archives such as [ENA](https://www.ebi.ac.uk/ena/browser/home)

Pipeline will have several modes

- `mags` for MAGs submission with **genome_submitter** wf
- `bins` for bins submission with **genome_submitter** wf
- `assemblies` for assembly submission with **assembly_submitter** wf

## Requirements

- Webin account registered https://www.ebi.ac.uk/ena/submit/webin/login
- Raw reads submitted into [INSDC](https://www.insdc.org/)

Setup your environment secrets before running the pipeline:

`nextflow secrets set WEBIN_ACCOUNT "Webin-XXX"`

`nextflow secrets set WEBIN_PASSWORD "XXX"`

Make sure you update with your authorised credentials.

## genome_submitter

Workflow to submit MAGs and/or bins to ENA.

It takes input `samplesheet.csv` with fields required for [genome_uploader](https://github.com/EBI-Metagenomics/genome_uploader). Fields described in [docs](https://github.com/EBI-Metagenomics/genome_uploader/blob/main/README.md#input-tsv-and-fields).
For now workflow converts CSV into required TSV.

_Future implementation will consider missing fields (for example completeness and contamination) and would run steps to fill in the gaps._

<!-- TODO nf-core:
   Complete this sentence with a 2-3 sentence summary of what types of data the pipeline ingests, a brief overview of the
   major pipeline sections and the types of output it produces. You're giving an overview to someone new
   to nf-core here, in 15-20 seconds. For an example, see https://github.com/nf-core/rnaseq/blob/master/README.md#introduction
-->

<!-- TODO nf-core: Include a figure that guides the user through the major workflow steps. Many nf-core
     workflows use the "tube map" design for that. See https://nf-co.re/docs/guidelines/graphic_design/workflow_diagrams#examples for examples.   -->
<!-- TODO nf-core: Fill in short bullet-pointed list of the default steps in the pipeline -->2. Present QC for raw reads ([`MultiQC`](http://multiqc.info/))

## Usage

> [!NOTE]
> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow. Make sure to [test your setup](https://nf-co.re/docs/usage/introduction#how-to-run-a-pipeline) with `-profile test` before running the workflow on actual data.

<!-- TODO nf-core: Describe the minimum required steps to execute the pipeline, e.g. how to prepare samplesheets.
     Explain what rows and columns represent. For instance (please edit as appropriate):
First, prepare a samplesheet with your input data that looks as follows:
`samplesheet.csv`:
```csv
sample,fastq_1,fastq_2
CONTROL_REP1,AEG588A1_S1_L002_R1_001.fastq.gz,AEG588A1_S1_L002_R2_001.fastq.gz
```
Each row represents a fastq file (single-end) or a pair of fastq files (paired end).
-->

Now, you can run the pipeline using:

<!-- TODO nf-core: update the following command to include all required parameters for a minimal example -->

```bash
nextflow run nf-core/seqsubmit \
   -profile <docker/singularity/.../institute> \
   --input samplesheet.csv \
   --outdir <OUTDIR>
```

> [!WARNING]
> Please provide pipeline parameters via the CLI or Nextflow `-params-file` option. Custom config files including those provided by the `-c` Nextflow option can be used to provide any configuration _**except for parameters**_; see [docs](https://nf-co.re/docs/usage/getting_started/configuration#custom-configuration-files).

For more details and further functionality, please refer to the [usage documentation](https://nf-co.re/seqsubmit/usage) and the [parameter documentation](https://nf-co.re/seqsubmit/parameters).

<!-- TODO nf-core:
## Pipeline output

To see the results of an example test run with a full size dataset refer to the [results](https://nf-co.re/seqsubmit/results) tab on the nf-core website pipeline page.
For more details about the output files and reports, please refer to the
[output documentation](https://nf-co.re/seqsubmit/output).
-->

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
