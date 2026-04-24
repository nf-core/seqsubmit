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
    ch_fasta                // channel: [ val(meta), path(fasta) ]
    ch_checkm2_db           // channel: [ val(meta), path(db) ] - pre-built db as directory
                            //          provide channel.empty() to trigger automatic download via ch_checkm2_db_zenodo_id
    ch_checkm2_db_zenodo_id // channel: [ val(meta), val(db_id) ] - db ID for CHECKM2_DATABASEDOWNLOAD (e.g. '1234567')
                            //          only used if ch_checkm2_db is empty

    main:
    ch_versions = channel.empty()

    //
    // Database preparation
    //

    // Download and prepare db from scratch if no pre-built db provided
    // Only trigger if ch_fasta has items
    ch_download_trigger = ch_checkm2_db
        .count()
        .filter { count -> count == 0 }  // Only proceed if ch_checkm2_db is empty
        .combine(ch_fasta.first())
        .combine(ch_checkm2_db_zenodo_id)
        .map { _count, _meta, _fasta, db_meta, db_id -> [db_meta, db_id] }

    CHECKM2_DATABASEDOWNLOAD(ch_download_trigger)

    // Combine db sources - one of these channels will be empty depending on inputs
    ch_db = ch_checkm2_db.mix(CHECKM2_DATABASEDOWNLOAD.out.database).first()

    //
    // Genome evaluation
    //

    CHECKM2_PREDICT(
        ch_fasta,
        ch_db,
    )

    emit:
    genome_evaluation = CHECKM2_PREDICT.out.checkm2_tsv  // channel: [ val(meta), path(tsv) ]
    stats_versions    = CHECKM2_PREDICT.out.versions_checkm2_predict

}
