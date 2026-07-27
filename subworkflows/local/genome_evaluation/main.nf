//
// Subworkflow that calculates completeness and contamination for genome
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CHECKM2_DATABASEDOWNLOAD } from '../../../modules/nf-core/checkm2/databasedownload/main'
include { CHECKM2_PREDICT          } from '../../../modules/nf-core/checkm2/predict/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOME_EVALUATION {

    take:
    ch_fasta                    // channel: [ val(meta), path(fasta) ]
    ch_checkm2_db               // val: path to local CheckM2 database or null to trigger automatic download
    ch_checkm2_db_download_id   // val: CheckM2 database Zenodo download ID

    main:

    //
    // Database preparation
    //
    ch_do_download = ch_fasta
        .first()
        .map { _meta_fasta -> ch_checkm2_db_download_id }

    // Download and prepare db from scratch if no pre-built db provided
    if (ch_checkm2_db) {
        ch_checkm2_db_ready = channel.value([[id: 'checkm2_db'], file(params.checkm2_db, checkIfExists: true)])
    } else {
        CHECKM2_DATABASEDOWNLOAD(ch_do_download)
        ch_checkm2_db_ready = CHECKM2_DATABASEDOWNLOAD.out.database
    }

    //
    // Genome evaluation
    //

    CHECKM2_PREDICT(
        ch_fasta,
        ch_checkm2_db_ready,
    )

    emit:
    genome_evaluation = CHECKM2_PREDICT.out.checkm2_tsv  // channel: [ val(meta), path(tsv) ]
    stats_versions    = CHECKM2_PREDICT.out.versions_checkm2_predict

}
