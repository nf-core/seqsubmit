//
// Subworkflow that calculates completeness and contamination for genome
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CHECKM2_DATABASEDOWNLOAD } from '../../modules/nf-core/checkm2/databasedownload/main'
include { CHECKM2_PREDICT          }          from '../../modules/nf-core/checkm2/predict/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOME_EVALUATION {

    take:
    ch_fasta   // [meta, fasta_file]

    main:
    ch_versions = channel.empty()

    // Run checkM2 database download if there is no db path provided
    if (!params.checkm2_db || !file(params.checkm2_db).exists()) {
        CHECKM2_DATABASEDOWNLOAD(params.checkm2_db_zenodo_id)
        ch_check2_db = CHECKM2_DATABASEDOWNLOAD.out.database
    }
    else {
        ch_check2_db = channel.of(
            [
                [id: "checkm2_db"],
                file(params.checkm2_db),
            ]
        )
    }

    CHECKM2_PREDICT(
        ch_fasta,
        ch_check2_db,
    )

    emit:
    genome_evaluation = CHECKM2_PREDICT.out.checkm2_tsv  // [meta, stats.tsv]
    stats_versions = CHECKM2_PREDICT.out.versions_checkm2_predict

}
