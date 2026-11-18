//
// Subworkflow that calculates completeness and contamination for prokaryotic genomes
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { CHECKM2_DATABASEDOWNLOAD } from '../../../modules/nf-core/checkm2/databasedownload/main'
include { CHECKM2_PREDICT          } from '../../../modules/nf-core/checkm2/predict/main'

include { parseStatsTable; mergeSoftware } from '../utils_nfcore_seqsubmit_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PROKARYOTIC_GENOME_EVALUATION {

    take:
    ch_fasta                     // channel: [ val(meta), path(fasta) ] - prokaryotic genomes only
    ch_checkm2_db                // val: path to local CheckM2 database or null to trigger automatic download
    ch_checkm2_db_download_id    // val: CheckM2 database Zenodo download ID

    main:

    // Database preparation for checkm2
    // that step would be launched only if input is not empty
    ch_do_download = ch_fasta
        .first()
        .map { _meta_fasta -> ch_checkm2_db_download_id }

    // Download and prepare db from scratch if no pre-built db provided
    if (ch_checkm2_db) {
        ch_checkm2_db_ready = channel.value([[id: 'checkm2_db'], file(ch_checkm2_db, checkIfExists: true)])
    } else {
        CHECKM2_DATABASEDOWNLOAD(ch_do_download)
        ch_checkm2_db_ready = CHECKM2_DATABASEDOWNLOAD.out.database
    }

    // Genome evaluation with CheckM2

    CHECKM2_PREDICT(
        ch_fasta,
        ch_checkm2_db_ready,
    )

    // ------ Completeness and contamination from CheckM2
    // Tools are listed in stats_generation_software separated by ';'.
    // If stats_generation_software is given in the samplesheet, CheckM2 is appended to it.

    // Software name with version, e.g. checkm2_v1.0.2
    def checkm2_software = CHECKM2_PREDICT.out.versions_checkm2_predict
        .map { _process_name, tool_name, version -> "${tool_name}_v${version}" }
        .first()

    ch_prok_stats = CHECKM2_PREDICT.out.checkm2_tsv
        .combine(checkm2_software)
        .map { meta, table, software -> parseStatsTable(meta, table, software) }
        .map { meta, completeness, contamination, software ->
            [ meta, completeness, contamination, mergeSoftware(meta.stats_generation_software, [software]) ]
        }

    emit:
    stats = ch_prok_stats  // channel: [ val(meta), val(completeness), val(contamination), val(stats_generation_software) ]

}
