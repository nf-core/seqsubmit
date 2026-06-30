---
title: Contributing
markdownPlugin: checklist
---

# `nf-core/seqsubmit`: Contributing guidelines

Hi there!
Thanks for taking an interest in improving nf-core/seqsubmit.

This page describes the recommended nf-core way to contribute to both nf-core/seqsubmit and nf-core pipelines in general, including:

- [General contribution guidelines](#general-contribution-guidelines): common procedures or guides across all nf-core pipelines.
- [Pipeline-specific contribution guidelines](#pipeline-specific-contribution-guidelines): procedures or guides specific to the development conventions of nf-core/seqsubmit.

> [!NOTE]
> If you need help using or modifying nf-core/seqsubmit, ask on the nf-core Slack [#seqsubmit](https://nfcore.slack.com/channels/seqsubmit) channel ([join our Slack here](https://nf-co.re/join/slack)).

## General contribution guidelines

### Contribution quick start

To contribute code to any nf-core pipeline:

- [ ] Ensure you have Nextflow, nf-core tools, and nf-test installed. See the [nf-core/tools repository](https://github.com/nf-core/tools) for instructions.
- [ ] Check whether a GitHub [issue](https://github.com/nf-core/seqsubmit/issues) about your idea already exists. If an issue does not exist, create one so that others are aware you are working on it.
- [ ] [Fork](https://help.github.com/en/github/getting-started-with-github/fork-a-repo) the [nf-core/seqsubmit repository](https://github.com/nf-core/seqsubmit) to your GitHub account.
- [ ] Create a branch on your forked repository and make your changes following [pipeline conventions](#pipeline-contribution-conventions) (if applicable).
- [ ] To fix major bugs, name your branch `patch` and follow the [patch release](#patch-release) process.
- [ ] Update relevant documentation within the `docs/` folder, use nf-core/tools to update `nextflow_schema.json`, and update `CITATIONS.md`.
- [ ] Run and/or update tests. See [Testing](#testing) for more information.
- [ ] [Lint](#lint-tests) your code with nf-core/tools.
- [ ] Submit a pull request (PR) against the `dev` branch and request a review.

If you are not used to this workflow with Git, see the [GitHub documentation](https://help.github.com/en/github/collaborating-with-issues-and-pull-requests) or [Git resources](https://try.github.io/) for more information.

## Use of AI and LLMs

The nf-core stance on the use of AI and LLMs is that humans are still ultimately responsible for their submitted code, regardless of the tools they use.

If you’re using AI tools, try to stick by these guidelines:

- Keep PRs as small and focussed as possible
- Avoid any unnecessary changes, such as moving or refactoring code (unless that is the explicit intention of the PR)
- Review all generated code yourself before opening a PR, and ensure that you understand it
- Engage with the community review process and expect to make revisions

For more detail, see the the [blog post](https://nf-co.re/blog/2026/statement-on-ai) for a statement from the nf-core/core team.

### Getting help

For further information and help, see the [nf-core/seqsubmit documentation](https://nf-co.re/seqsubmit/usage) or ask on the nf-core [#seqsubmit](https://nfcore.slack.com/channels/seqsubmit) Slack channel ([join our Slack here](https://nf-co.re/join/slack)).

### GitHub Codespaces

You can contribute to nf-core/seqsubmit without installing a local development environment on your machine by using [GitHub Codespaces](https://github.com/codespaces).

[GitHub Codespaces](https://github.com/codespaces) is an online developer environment that runs in your browser, complete with VS Code and a terminal.
Most nf-core repositories include a devcontainer configuration, which creates a GitHub Codespaces environment specifically for Nextflow development.
The environment includes pre-installed nf-core tools, Nextflow, and a few other helpful utilities via a Docker container.

To get started, open the repository in [Codespaces](https://github.com/nf-core/seqsubmit/codespaces).

### Testing

Once you have made your changes, run the pipeline with nf-test to test them locally.
For additional information, use the `--verbose` flag to view the Nextflow console log output.

```bash
nf-test test --tag test --profile +docker --verbose
```

If you have added new functionality, ensure you update the test assertions in the `.nf.test` files in the `tests/` directory.
Update the snapshots with the following command:

```bash
nf-test test --tag test --profile +docker --verbose --update-snapshots
```

When you create a pull request with changes, GitHub Actions will run automatic tests.
Pull requests are typically reviewed when these tests are passing.

Two types of tests are typically run:

#### Lint tests

nf-core has a [set of guidelines](https://nf-co.re/docs/specifications/overview) which all pipelines must follow.
To enforce these, run linting with nf-core/tools:

```bash
nf-core pipelines lint <pipeline_directory>
```

If you encounter failures or warnings, follow the linked documentation printed to screen.
For more information about linting tests, see [nf-core/tools API documentation](https://nf-co.re/docs/nf-core-tools/api_reference/latest/pipeline_lint_tests/actions_awsfulltest).

#### Pipeline tests

Each nf-core pipeline should be set up with a minimal set of test data.
GitHub Actions runs the pipeline on this data to ensure it runs through and exits successfully.
If there are any failures then the automated tests fail.
These tests are run with the latest available version of Nextflow and the minimum required version specified in the pipeline code.

### Patch release

> [!WARNING]
> Only in the unlikely event of a release that contains a critical bug.

- [ ] Create a new branch `patch` on your fork based on `upstream/main` or `upstream/master`.
- [ ] Fix the bug and use nf-core/tools to bump the version to the next semantic version, for example, `1.2.3` → `1.2.4`.
- [ ] Open a Pull Request from `patch` directly to `main`/`master` with the changes.

### Pipeline contribution conventions

nf-core semi-standardises how you write code and other contributions to make the nf-core/seqsubmit code and processing logic more understandable for new contributors and to ensure quality.

#### Add a new pipeline step

To contribute a new step to the pipeline, follow the general nf-core coding procedure.
Please also refer to the [pipeline-specific contribution guidelines](#pipeline-specific-contribution-guidelines):

- [ ] Define the corresponding [input channel](#channel-naming-schemes) into your new process from the expected previous process channel.
- [ ] Install a module with nf-core/tools, or write a local module (see [default processes resource requirements](#default-processes-resource-requirements)), and add it to the target `<workflow>.nf`.
- [ ] Define the output channel if needed. Mix the version output channel into `ch_versions` and relevant files into `ch_multiqc`.
- [ ] Add new or updated parameters to `nextflow.config` with a [default value](#default-parameter-values).
- [ ] Add new or updated parameters and relevant help text to `nextflow_schema.json` with [nf-core/tools](#default-parameter-values).
- [ ] Add validation for relevant parameters to the pipeline utilisation section of `utils_nfcore_\_pipeline/main.nf` subworkflow.
- [ ] Perform local tests to validate that the new code works as expected.
  - [ ] If applicable, add a new test in the `tests` directory.
- [ ] Update `usage.md`, `output.md`, and `citation.md` as appropriate.
- [ ] [Lint](lint) the code with nf-core/tools.
- [ ] Update any diagrams or pipeline images as necessary.
- [ ] Update MultiQC config `assets/multiqc_config.yml` so relevant suffixes, file name cleanup, and module plots are in the appropriate order.
- [ ] If applicable, create a [MultiQC](https://seqera.io/multiqc/) module.
- [ ] Add a description of the output files and, if relevant, images from the MultiQC report to `docs/output.md`.

To update the minimum required Nextflow version, see the [Nextflow version bumping](#nextflow-version-bumping) section below. For more information about pipeline contributions, see [pipeline-specific contribution guidelines](#pipeline-specific-contribution-guidelines).

#### Channel naming schemes

Use the following naming schemes for channels to make the channel flow easier to understand:

- Initial process channel: `ch_output_from_<process>`
- Intermediate and terminal channels: `ch_<previousprocess>_for_<nextprocess>`

#### Default parameter values

Parameters should be initialised and defined with default values within the `params` scope in `nextflow.config`.
They should also be documented in the pipeline JSON schema.

To update `nextflow_schema.json`, run:

```bash
nf-core pipelines schema build
```

The schema builder interface that loads in your browser should automatically update the defaults in the parameter documentation.

#### Default processes resource requirements

If you write a local module, specify a default set of resource requirements for the process.

Sensible defaults for process resource requirements (CPUs, memory, time) should be defined in `conf/base.config`.
Specify these with generic `withLabel:` selectors, so they can be shared across multiple processes and steps of the pipeline.

nf-core provides a set of standard labels that you should follow where possible, as seen in the [nf-core pipeline template](https://github.com/nf-core/tools/blob/main/nf_core/pipeline-template/conf/base.config).
These labels define resource defaults for single-core processes, modules that require a GPU, and different levels of multi-core configurations with increasing memory requirements.

Values assigned within these labels can be dynamically passed to a tool using the the `${task.cpus}` and `${task.memory}` Nextflow variables in the `script:` block of a module (see an example in the [modules repository](https://github.com/nf-core/modules/blob/bd1b6a40f55933d94b8c9ca94ec8c1ea0eaf4b82/modules/nf-core/samtools/bam2fq/main.nf#L30)).

#### Nextflow version bumping

If you use a new feature from core Nextflow, bump the minimum required Nextflow version in the pipeline with:

```bash
nf-core pipelines bump-version --nextflow . <min_nf_version>
```

#### Images and figures guidelines

If you update images or graphics, follow the nf-core [style guidelines](https://nf-co.re/docs/community/brand/workflow-schematics).

## Pipeline specific contribution guidelines

To ensure consistency and maintainability of the nf-core/seqsubmit pipeline, contributors should follow these guidelines when implementing new features or modifying existing functionality.

1. Understand Workflow Structure

The pipeline consists of independent workflows, each corresponding to a certain data type:

* GENOMESUBMIT (mags, bins)
* ASSEMBLYSUBMIT (metagenomic_assemblies)
* READSUBMIT (raw reads)

When adding new functionality (e.g. a new submission mode such as `isolate_genomes`), ensure that:

* It integrates cleanly into the appropriate workflow or introduces a well-structured new one.
* Existing workflows remain unaffected unless changes are explicitly required.
* Shared logic is abstracted into reusable modules or subworkflows where possible.

⸻

2. Follow Samplesheet and Schema-Driven Design

All inputs in seqsubmit are defined via strict samplesheet schemas.

* Any new feature must:
    * Extend or introduce a corresponding schema (assets/schema_input_*.json)
    * Clearly define required and optional fields
* Maintain:
    * Column order consistency (critical for pipeline execution)
    * Backward compatibility where possible
* Avoid duplicating metadata logic—reuse existing parsing and validation patterns.

⸻

3. ENA Submission Requirements

Submissions to [ENA](https://www.ebi.ac.uk/ena/browser/home) are governed by a well-defined data model and submission process. These include relationships between entities (e.g. studies, samples, experiments, runs, analyses), required submission steps, and accepted file types and formats.

Contributors should refer directly to the [official ENA documentation](https://ena-docs.readthedocs.io/en/latest/submit/general-guide.html) to understand latest submission requirements and ensure that pipeline behaviour remains aligned with ENA standards.

    Follow ENA-defined submission workflows and required steps for each data type
* Ensure that:
    * New pipeline workflows follow ENA-defined submission workflows and required steps for each data type
    * Metadata fields align with ENA requirements
    * Controlled vocabularies (e.g. platform, library strategy) are respected
* Where possible:
    * Validate early (before submission steps)
    * Provide clear error messages for invalid metadata

⸻

4. Integration with Webin-CLI

All submissions are performed via [Webin-CLI](https://github.com/enasequence/webin-cli). Contributors should rely on official Webin-CLI documentation to understand expected inputs, parameters, and modes of operation. Make sure to always use the latest version of the tool.

* Contributions affecting submission logic must:
    * Respect --webincli_mode (validate vs submit)
    * Support --test_upload for safe testing against ENA test server
* Never introduce changes that:
    * Risk accidental submission to production without explicit user intent
* Ensure compatibility with:
    * Credential handling via Nextflow secrets (ENA_WEBIN, ENA_WEBIN_PASSWORD)

⸻

5. Testing Requirements

All new functionality must be covered by tests.

At minimum, include:

* nf-test unit tests for new modules/processes
* Updates to test profiles where relevant
* Lightweight test data (small FASTA/FASTQ) stored at https://github.com/nf-core/test-datasets/tree/seqsubmit

Where applicable:

* Test both:
    * Validation mode (`--webincli_mode validate`)
    * Submission mode with --test_upload (`--webincli_mode submit --test_upload`)
* Ensure tests are:
    * Fast
    * Reproducible
    * Independent of large external resources (for example databases download) if possible

⸻

6. Performance and Resource Awareness

Some data processing steps may be resource-intensive (e.g. database preparation for CAT_pack). When introducing new workflows or features avoid unnecessary recomputation. Add option to reuse cached results or provide prebuilt databases when possible.

⸻

7. Documentation and Usability

Every contribution should improve usability:

* Update:
    * README.md
    * docs/usage.md
    * Schema descriptions
* Provide:
    * Clear examples (e.g. samplesheets)
    * Meaningful parameter descriptions

The goal is to ensure that users can successfully submit data without needing deep knowledge of ENA submission requirements.

⸻

8. Design Principles

When contributing, prioritise:

* Reproducibility (consistent results across environments)
* Automation (minimise manual user intervention)
* Clarity (explicit inputs and outputs)
* Extensibility (easy to add new submission types)

⸻

By following these guidelines, contributors help ensure that nf-core/seqsubmit remains a robust, user-friendly, and extensible solution for genomic data submission workflows.
