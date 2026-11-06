/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap       } from 'plugin/nf-schema'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

include { GENOMESUBMIT           } from './genomesubmit'
include { ASSEMBLYSUBMIT         } from './assemblysubmit'
include { READSUBMIT             } from './readsubmit'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow SEQSUBMIT {

    take:
    ch_samplesheet // channel: samplesheet read in from --input
    multiqc_config
    multiqc_logo
    multiqc_methods_description
    outdir
    mode                     // val: submission mode (mags, bins, metagenomic_assemblies or reads)
    submission_study         // val: accession of the study to submit to (optional)
    study_metadata           // val: path to study metadata file for study creation (used if no submission_study provided)
    trna_limit               // val: tRNA count threshold
    rrna_limit               // val: rRNA length percentage threshold
    checkm2_db               // val: path to CheckM2 database
    checkm2_db_download_id   // val: CheckM2 database download ID
    cat_db                   // val: path to CAT database
    centre_name              // val: submission centre name
    upload_tpa               // val: upload as TPA (Third Party Annotation)
    test_upload              // val: true for test upload mode
    webincli_mode            // val: either 'validate' or 'submit' to specify WebinCLI mode of operation
    is_private               // val: fetch metadata from private/public account
    release_date             // val: keep submitted data private until given date

    main:

    def ch_versions = channel.empty()
    def ch_multiqc_files = channel.empty()

    //
    // WORKFLOW: Run the submission workflow for the chosen mode
    //
    if (mode == "mags" || mode == "bins") {
        GENOMESUBMIT (
            ch_samplesheet,
            mode,
            submission_study,
            study_metadata,
            trna_limit,
            rrna_limit,
            checkm2_db,
            checkm2_db_download_id,
            cat_db,
            center_name,
            upload_tpa,
            test_upload,
            webincli_mode,
            is_private,
            release_date
        )
        ch_multiqc_files = ch_multiqc_files.mix(GENOMESUBMIT.out.multiqc_files)
    } else if (mode == "metagenomic_assemblies") {
        ASSEMBLYSUBMIT (
            ch_samplesheet,
            submission_study,
            study_metadata,
            upload_tpa,
            test_upload,
            webincli_mode,
            is_private,
            release_date,
            center_name
        )
        ch_multiqc_files = ch_multiqc_files.mix(ASSEMBLYSUBMIT.out.multiqc_files)
    } else if (mode == "reads") {
        READSUBMIT (
            ch_samplesheet,
            submission_study,
            study_metadata,
            test_upload,
            webincli_mode,
            release_date,
            center_name
        )
        ch_multiqc_files = ch_multiqc_files.mix(READSUBMIT.out.multiqc_files)
    }

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
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
