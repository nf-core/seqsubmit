/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { GENOME_UPLOAD as CREATE_MANIFESTS     } from '../modules/local/genome_upload'
include { ENA_WEBIN_CLI_WRAPPER as SUBMIT       } from '../modules/local/ena_webin_cli_wrapper'
include { REGISTERSTUDY                         } from '../modules/local/registerstudy/main'
include { RENAME_FASTA_FOR_CATPACK              } from '../modules/local/rename_fasta_for_catpack'
include { CREATE_GENOME_METADATA_TSV            } from '../modules/local/create_genome_metadata_tsv/main'

include { COVERM_GENOME                         } from '../modules/nf-core/coverm/genome'
include { FIND_CONCATENATE as CONCAT_METADATA   } from '../modules/nf-core/find/concatenate/main'
include { FIND_CONCATENATE as CONCAT_ACCESSIONS } from '../modules/nf-core/find/concatenate/main'
include { MULTIQC                               } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap                      } from 'plugin/nf-schema'

include { FASTA_VALIDATION                      } from '../subworkflows/local/fasta_validation/main'
include { GENOME_EVALUATION                     } from '../subworkflows/local/genome_evaluation/main'
include { RNA_DETECTION                         } from '../subworkflows/local/rna_detection/main'
include { FASTA_CLASSIFY_CATPACK                } from '../subworkflows/nf-core/fasta_classify_catpack/main'

include { paramsSummaryMultiqc                  } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML                } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText                } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOMESUBMIT {

    take:
    ch_samplesheet           // channel: samplesheet read in from --input
    multiqc_config
    multiqc_logo
    multiqc_methods_description
    outdir
    mags_or_bins_flag        // val: submission mode (mags or bins)
    submission_study         // val: accession of the study to submit to (optional)
    study_metadata           // val: path to study metadata file for study creation (used if no submission_study provided)
    trna_limit               // val: tRNA count threshold
    rrna_limit               // val: rRNA length percentage threshold
    checkm2_db               // val: path to CheckM2 database
    checkm2_db_download_id   // val: CheckM2 database download ID
    cat_db                   // val: path to CAT database
    cat_db_download_id       // val: CAT database download ID
    centre_name              // val: submission centre name
    upload_tpa               // val: upload as TPA (Third Party Annotation)
    test_upload              // val: true for test upload mode
    webincli_mode            // val: either 'validate' or 'submit' to specify WebinCLI mode of operation
    is_private               // val: fetch metadata from private/public account
    release_date             // val: keep submitted data private until given date

    main:

    def ch_versions = channel.empty()
    def ch_multiqc_files = channel.empty()

    // --------- Create genomes channel with proper metadata structure
    genome_fasta_and_reads = ch_samplesheet
        .map { meta, fasta, reads_1, reads_2 ->
            def new_meta = meta + [single_end: !reads_2]
            def reads = new_meta.single_end
                ? [reads_1]
                : [reads_1, reads_2]
            [new_meta, fasta, reads]
        }

    genome_fasta = genome_fasta_and_reads.map{meta, fasta, _fq1 -> [meta, fasta]}
    genome_reads = genome_fasta_and_reads.map{meta, _fasta, reads -> [meta, reads]}

    // --------- Check fasta files are properly formatted and filter out files with less than 2 contigs
    FASTA_VALIDATION (
        genome_fasta
    )

    // --------- Genome coverage calculation
    branched_coverage_results = FASTA_VALIDATION.out.valid_fastas
        .branch { meta, _fasta ->
            genome_coverage_ref_input: !(meta.genome_coverage)
            genome_coverage_present: true  // Everything else goes here
        }

    coverm_input = branched_coverage_results.genome_coverage_ref_input.join(genome_reads)
        .multiMap { meta, fasta, fastq ->
            genome: [ meta, fasta ]
            raw_reads: [ meta, fastq ]
        }

    COVERM_GENOME (
        coverm_input.raw_reads,
        coverm_input.genome,
        false,
        false,
        'file',
        false
    )

    // Update metadata for records missing coverage
    fasta_updated_with_coverage = COVERM_GENOME.out.coverage.join(branched_coverage_results.genome_coverage_ref_input)
        .map{ meta, coverage_tsv, fasta ->
              def lines = coverage_tsv.readLines()
              // support for empty coverage files required for -stub mode
              def coverage = lines ? lines[1].split('\t')[1] : null
              def updated_meta = meta.clone()
              updated_meta.genome_coverage = coverage
              return [updated_meta, fasta]
        }
        .mix(branched_coverage_results.genome_coverage_present)

    // --------- For genomes without RNA_presence info, calculate rRNA and tRNA
    branched_rna_results = fasta_updated_with_coverage
        .branch { meta, _fasta ->
            rna_prediction_input: meta.RNA_presence == null  // it might be True/False
            rna_present: true  // Everything else goes here
        }

    RNA_DETECTION (
        branched_rna_results.rna_prediction_input,
        trna_limit,
        rrna_limit
    )

    // Update metadata for records missing RNA
    fasta_updated_with_rna = RNA_DETECTION.out.rna_detected.join(branched_rna_results.rna_prediction_input)
        .map{ meta, rna_decision, fasta ->
              def lines = rna_decision.readLines()
              // support for empty decision files required for -stub mode
              def decision = lines ? lines[0].split('\t')[1].toLowerCase() == 'true' : null
              def updated_meta = meta.clone()
              updated_meta.RNA_presence = decision
              return [updated_meta, fasta]
        }
        .mix(branched_rna_results.rna_present)

    // --------- Completeness and contamination calculation
    branched_stats_results = fasta_updated_with_rna
        .branch { meta, _fasta ->
            genome_evaluation_input: !(meta.completeness) || !(meta.contamination) || !(meta.stats_generation_software)
            evaluation_present: true  // Everything else goes here
        }

    GENOME_EVALUATION (
        branched_stats_results.genome_evaluation_input,
        checkm2_db,
        checkm2_db_download_id
    )

    // Create a value channel with the version string
    def stats_version_ch = GENOME_EVALUATION.out.stats_versions
        .map { _process_name, tool_name, version_output -> return "${tool_name}_v${version_output}"
        }.first()

    fasta_updated_with_stats = GENOME_EVALUATION.out.genome_evaluation
        .join(branched_stats_results.genome_evaluation_input)
        .combine(stats_version_ch)
        .map { meta, stats_tsv, fasta, stats_version ->
            def lines = stats_tsv.readLines()
            // support for empty checkm files required for -stub mode
            def updated_meta = meta.clone()
            updated_meta.completeness = lines ? lines[1].split('\t')[1] : null
            updated_meta.contamination = lines ? lines[1].split('\t')[2] : null
            updated_meta.stats_generation_software = stats_version
            return [updated_meta, fasta]
        }
        .mix(branched_stats_results.evaluation_present)

    // --------- Taxonomy
    branched_taxonomy_results = fasta_updated_with_stats
        .branch { meta, _fasta ->
            genome_taxonomy_input: !(meta.NCBI_lineage)
            taxonomy_present: true  // Everything else goes here
        }

    // Change extension for all files required taxonomy to .fasta because CATPACK requires suffix as input
    RENAME_FASTA_FOR_CATPACK (
        branched_taxonomy_results.genome_taxonomy_input
    )

    // build input structures for CAT_DB depending on what provided as input
    def cat_db_input = cat_db
        ? channel.of( [['id': 'CAT_DB'], file(cat_db)] )
        : channel.empty()

    def cat_db_id_input = (!cat_db && cat_db_download_id)
        ? channel.of( [['id': 'CAT_DB_id'], cat_db_download_id] )
        : channel.empty()

    FASTA_CLASSIFY_CATPACK (
        RENAME_FASTA_FOR_CATPACK.out.renamed_fasta,  // ch_bins
        channel.empty(),                             // ch_contigs - empty because we classify bins, not contigs
        cat_db_input,
        cat_db_id_input,
        false,                                       // disable summary generation
        '.fasta'                                     // bin_suffix - the suffix of the renamed fasta files
    )

    fasta_updated_with_taxonomy = FASTA_CLASSIFY_CATPACK.out.bat_classification
        .join(branched_taxonomy_results.genome_taxonomy_input)
        .map { meta, taxa_tsv, fasta ->
            def lines = taxa_tsv.readLines()
            def updated_meta = meta.clone()
            // support for empty taxonomy files required for -stub mode
            updated_meta.NCBI_lineage = lines ? lines[1].split('\t')[3] : null
            return [updated_meta, fasta]
        }
        .mix(branched_taxonomy_results.taxonomy_present)

    // --------- Combine metadata into TSV using module
    CREATE_GENOME_METADATA_TSV (
        fasta_updated_with_taxonomy
    )

    // Collect all TSV rows into a single file
    CONCAT_METADATA (
        CREATE_GENOME_METADATA_TSV.out.tsv.map { _meta, file -> file }.collect().map { files -> [ [id: "genomes_metadata"], files ] },
        'true' // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    // --------- Register study if accession not provided via --submission_study
    def study_accession_ch
    if (submission_study) {
        study_accession_ch = channel.of(submission_study)
    } else {
        REGISTERSTUDY(
            channel.of([[id: "study"], file(study_metadata)]),
            test_upload,
            release_date
        )

        study_accession_ch = REGISTERSTUDY.out.accessions
            .map { _meta, json ->
                def data = new groovy.json.JsonSlurper().parse(json)
                data.submitted[0]?.accession
            }
    }

    // --------- Generate manifests
    CREATE_MANIFESTS(
        fasta_updated_with_taxonomy.map{_meta, fasta -> fasta}.collect(),
        CONCAT_METADATA.out.file_out.map { _meta, file -> file }.first(),
        mags_or_bins_flag,     // mags or bins
        study_accession_ch.first(),
        centre_name,
        upload_tpa,
        test_upload,
        is_private
    )

    // All manifests were generated in one run
    // Manifests should be separated into different channels using prefix as id
    manifests_ch = CREATE_MANIFESTS.out.manifests.flatten()
        .map { manifest ->
            def prefix = test_upload ?
                manifest.name.replaceAll(/_\d+\.manifest$/, '') :  // Remove extension and hash suffix appended in test mode
                manifest.name.replaceAll(/\.manifest$/, '')        // Remove only extension in live mode
            def meta = [id: prefix]
            [ meta, manifest ]
    }
    // Combine fasta and manifests
    ch_combined = fasta_updated_with_taxonomy
        .map { meta, fasta -> [meta.id, meta, fasta] }
        .join(
            manifests_ch.map { meta, manifest -> [meta.id, manifest] }  // Has only [id: prefix]
        )
        .map { _id, full_meta, fasta, manifest ->
            [full_meta, fasta, manifest]
        }

    // --------- Upload data to ENA
    SUBMIT (
        ch_combined,
        test_upload,
        webincli_mode,
        "genome"
    )

    // Concatenate accessions into single file to publish
    CONCAT_ACCESSIONS (
        SUBMIT.out.accessions.map { _meta, file -> file }.collect().map { files -> [ [id: "genomes_accessions"], files ] },
        'true' // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    // --------- Collate and save software versions
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name: 'nf_core_'  +  'seqsubmit_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    // --------- MODULE: MultiQC
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    def ch_summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def ch_workflow_summary = channel.value(paramsSummaryMultiqc(ch_summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    def ch_multiqc_custom_methods_description = multiqc_methods_description
        ? file(multiqc_methods_description, checkIfExists: true)
        : file("${projectDir}/assets/methods_description_template.yml", checkIfExists: true)
    def ch_methods_description = channel.value(methodsDescriptionText(ch_multiqc_custom_methods_description))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: true))
    ch_multiqc_files = ch_multiqc_files.mix(CONCAT_METADATA.out.file_out.map{_meta, file -> file})
    ch_multiqc_files = ch_multiqc_files.mix(CREATE_MANIFESTS.out.upload_registered_mags)
    ch_multiqc_files = ch_multiqc_files.mix(CONCAT_ACCESSIONS.out.file_out.map{_meta, file -> file})
    MULTIQC(
        ch_multiqc_files.flatten().collect().map { files ->
            [
                [id: 'seqsubmit'],
                files,
                multiqc_config
                    ? file(multiqc_config, checkIfExists: true)
                    : file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true),
                multiqc_logo ? file(multiqc_logo, checkIfExists: true) : [],
                [],
                [],
            ]
        }
    )
    emit:
    multiqc_report = MULTIQC.out.report.map { _meta, report -> [report] }.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
