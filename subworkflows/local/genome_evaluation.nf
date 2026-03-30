//
// Subworkflow that calculates completeness and contamination for genome
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CHECKM2_DATABASEDOWNLOAD } from '../../modules/nf-core/checkm2/databasedownload/main'
include { CHECKM2_PREDICT          } from '../../modules/nf-core/checkm2/predict/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOME_EVALUATION {

    take:
    ch_fasta   // channel: [ val(meta), path(fasta) ]

    main:
    ch_versions = channel.empty()

    //
    // Database preparation
    //

    if (!params.checkm2_db || !file(params.checkm2_db).exists()) {
        // Conditional download: only trigger if ch_fasta has items
        ch_download_trigger = ch_fasta
            .map { _meta, _fasta -> params.checkm2_db_zenodo_id }
            .first()  // Only need one trigger regardless of how many fasta files

        CHECKM2_DATABASEDOWNLOAD(ch_download_trigger)
        ch_checkm2_db = CHECKM2_DATABASEDOWNLOAD.out.database
    }
    else {
        // Use existing database
        ch_checkm2_db = channel.of(
            [
                [id: "checkm2_db"],
                file(params.checkm2_db),
            ]
        )
    }

    //
    // Genome evaluation
    //

    CHECKM2_PREDICT(
        ch_fasta,
        ch_checkm2_db,
    )

    emit:
    genome_evaluation = CHECKM2_PREDICT.out.checkm2_tsv  // channel: [ val(meta), path(tsv) ]
    stats_versions    = CHECKM2_PREDICT.out.versions_checkm2_predict

}
