/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CREATE_READS_MANIFEST              } from '../modules/local/create_reads_manifest/main'
include { ENA_WEBIN_CLI_WRAPPER as SUBMIT    } from '../modules/local/ena_webin_cli_wrapper'
include { REGISTERSTUDY                      } from '../modules/local/registerstudy/main'

include { FIND_CONCATENATE as CONCAT_ACCESSIONS } from '../modules/nf-core/find/concatenate/main'
include { MULTIQC                            } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap                   } from 'plugin/nf-schema'

include { paramsSummaryMultiqc               } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML             } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText             } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN THE WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow READSUBMIT {

    take:
    ch_samplesheet       // channel: samplesheet read in from --input
    multiqc_config
    multiqc_logo
    multiqc_methods_description
    outdir
    submission_study     // val: ENA study accession for all reads in this run (optional).
                         // NOTE: all samples must belong to the same study and Webin account.
                         // Submitting reads across multiple studies or Webin accounts in a
                         // single pipeline run is not supported.
    study_metadata       // val: path to study metadata file for study creation (used if no submission_study provided)
    test_upload          // val: true for test upload mode
    webincli_mode        // val: either 'validate' or 'submit' to specify WebinCLI mode of operation
    release_date         // val: keep submitted data private until given date

    main:
    def ch_versions = channel.empty()
    def ch_multiqc_files = channel.empty()

    // Create reads channel with proper metadata structure
    reads_ch = ch_samplesheet
        .map { row ->
            def (meta_in, sample_accession, fastq_1, fastq_2,
                 platform, instrument, library_source, library_selection, library_strategy,
                 insert_size, library_name, description) = row
            def meta = [
                id: meta_in.id,
                sample_accession: sample_accession,
                single_end: fastq_2 ? false : true,
                platform: platform,
                instrument: instrument,
                library_source: library_source,
                library_selection: library_selection,
                library_strategy: library_strategy,
                insert_size: insert_size ?: null,
                library_name: library_name ?: null,
                description: description ?: null
            ]

            if (fastq_2 && fastq_2 != "") {
                // If paired end reads
                [meta, [file(fastq_1), file(fastq_2)]]
            } else {
                // If single end
                [meta, file(fastq_1)]
            }
        }

    if (!submission_study && !study_metadata) {
        error("Either --submission_study or --study_metadata must be provided")
    }
    def study_accession_ch
    if (submission_study) {
        // Use provided study accession directly
        study_accession_ch = channel.of(submission_study)
    } else {
        // Register a new study using the study metadata file
        REGISTERSTUDY(
            channel.of([[id: "study"], file(study_metadata)]),
            test_upload,
            release_date
        )
        ch_versions = ch_versions.mix(REGISTERSTUDY.out.versions)
        study_accession_ch = REGISTERSTUDY.out.accessions
            .map { _meta, json ->
                def data = new groovy.json.JsonSlurper().parse(json)
                data.submitted[0]?.accession
            }
    }

    // Generate reads manifest files
    CREATE_READS_MANIFEST(
        reads_ch,
        study_accession_ch.first()
    )

    // Prepare input for submission with manifest and fastq files
    submission_input = reads_ch.join(CREATE_READS_MANIFEST.out.manifest)
        .map { meta, fastq, manifest ->
            [meta, fastq, manifest]
        }

    SUBMIT (
        submission_input,
        test_upload,
        webincli_mode,
        "reads"
    )
    ch_versions = ch_versions.mix(SUBMIT.out.versions)

    // Concatenate accessions into single file to publish
    CONCAT_ACCESSIONS (
        SUBMIT.out.accessions.map { _meta, file -> file }.collect().map { files -> [ [id: "reads_accessions"], files ] },
        true // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    //
    // Collate and save software versions
    //
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

    //
    // MODULE: MultiQC
    //
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    def ch_summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def ch_workflow_summary = channel.value(paramsSummaryMultiqc(ch_summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    def ch_multiqc_custom_methods_description = multiqc_methods_description
        ? file(multiqc_methods_description, checkIfExists: true)
        : file("${projectDir}/assets/methods_description_template.yml", checkIfExists: true)
    def ch_methods_description = channel.value(methodsDescriptionText(ch_multiqc_custom_methods_description))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: true))
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
