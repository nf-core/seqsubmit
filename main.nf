#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    nf-core/seqsubmit
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Github : https://github.com/nf-core/seqsubmit
    Website: https://nf-co.re/seqsubmit
    Slack  : https://nfcore.slack.com/channels/seqsubmit
----------------------------------------------------------------------------------------
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS / WORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { GENOMESUBMIT            } from './workflows/genomesubmit'
include { ASSEMBLYSUBMIT          } from './workflows/assemblysubmit'
include { PIPELINE_INITIALISATION } from './subworkflows/local/utils_nfcore_seqsubmit_pipeline'
include { PIPELINE_COMPLETION     } from './subworkflows/local/utils_nfcore_seqsubmit_pipeline'
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NAMED WORKFLOWS FOR PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// WORKFLOW: Run main analysis pipeline depending on type of input
//
workflow NFCORE_SEQSUBMIT {

    take:
    samplesheet // channel: samplesheet read in from --input

    main:
    ch_multiqc_report = channel.empty()
    //
    // WORKFLOW: Run pipeline
    //
    // Depending on the input type (mags/bins or metagenomic_assemblies), one or the another workflow will be triggered
    if (params.mode == "mags" || params.mode == "bins") {
        GENOMESUBMIT (
            samplesheet,
            params.mode,
            params.submission_study,
            params.study_metadata,
            params.trna_limit,
            params.rrna_limit,
            params.checkm2_db,
            params.checkm2_db_download_id,
            params.cat_db,
            params.cat_db_download_id,
            params.centre_name,
            params.upload_tpa,
            params.test_upload,
            params.webin_cli_version,
            params.webincli_mode,
            params.outdir
        )
        ch_multiqc_report = GENOMESUBMIT.out.multiqc_report
    } else if (params.mode == "metagenomic_assemblies") {
        ASSEMBLYSUBMIT (
            samplesheet,
            params.submission_study,
            params.study_metadata,
            params.upload_tpa,
            params.test_upload,
            params.webin_cli_version,
            params.webincli_mode,
            params.outdir
        )
        ch_multiqc_report = ASSEMBLYSUBMIT.out.multiqc_report
    }


    emit:
    multiqc_report = ch_multiqc_report // channel: /path/to/multiqc_report.html
}
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow {

    main:
    //
    // SUBWORKFLOW: Run initialisation tasks
    //

    PIPELINE_INITIALISATION (
        params.version,
        params.validate_params,
        args,
        params.outdir,
        params.input,
        params.mode,
        params.help,
        params.help_full,
        params.show_hidden
    )

    //
    // WORKFLOW: Run main workflow
    //
    NFCORE_SEQSUBMIT (
        PIPELINE_INITIALISATION.out.samplesheet
    )
    //
    // SUBWORKFLOW: Run completion tasks
    //
    PIPELINE_COMPLETION (
        params.email,
        params.email_on_fail,
        params.plaintext_email,
        params.outdir,
        params.monochrome_logs,
        params.hook_url,
        NFCORE_SEQSUBMIT.out.multiqc_report
    )
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
