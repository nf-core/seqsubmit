//
// Subworkflow that calculates completeness and contamination for genome
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { BUSCO_BUSCO              } from '../../../modules/nf-core/busco/busco/main'
include { CHECKM2_DATABASEDOWNLOAD } from '../../../modules/nf-core/checkm2/databasedownload/main'
include { CHECKM2_PREDICT          } from '../../../modules/nf-core/checkm2/predict/main'
include { UNTAR as BUSCO_UNTAR     } from '../../../modules/nf-core/untar/main'

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
    busco_db_lineage            // val: lineage for checking against, default: auto_euk
    ch_busco_db                 // path(fasta) or []
    busco_clean                 // boolean: clean intermediate busco files

    main:

    // ------ split input to Prokaryotes and Eukaryotes

    domain_split_fasta = ch_fasta
        .branch { meta, fasta ->
            proks: meta.domain in ['arc', 'bac']
            euks:  meta.domain == 'euk'
        }

    // ------ Prokaryotes

    // Database preparation for checkm2
    // that step would be launched only if proks branch is not empty
    ch_do_download = domain_split_fasta.proks
        .first()
        .map { _meta_fasta -> ch_checkm2_db_download_id }

    // Download and prepare db from scratch if no pre-built db provided
    if (ch_checkm2_db) {
        ch_checkm2_db_ready = channel.value([[id: 'checkm2_db'], file(params.checkm2_db, checkIfExists: true)])
    } else {
        CHECKM2_DATABASEDOWNLOAD(ch_do_download)
        ch_checkm2_db_ready = CHECKM2_DATABASEDOWNLOAD.out.database
    }

    // Genome evaluation with CheckM2

    CHECKM2_PREDICT(
        domain_split_fasta.proks,
        ch_checkm2_db_ready,
    )

    // ------ Eukaryotes

    // Prepare database object depending on type
    // If directory, assumes sub structure of `busco_db/lineages/<taxa>_odb(10|12)`

    if (ch_busco_db && ch_busco_db.extension in ['gz', 'tgz']) {
        // Only untar if there is at least one eukaryotic genome
        ch_busco_untar_in = domain_split_fasta.euks
            .first()
            .map { _meta, _fasta -> [[id: ch_busco_db.simpleName], ch_busco_db] }
        BUSCO_UNTAR(ch_busco_untar_in)
        ch_busco_db = BUSCO_UNTAR.out.untar.map { _meta, db -> db }.first()
    }
    else if (ch_busco_db && ch_busco_db.isDirectory()) {
        ch_busco_db = ch_busco_db
    }
    else {
        ch_busco_db = []
    }

    // Genome evaluation with BUSCO

    BUSCO_BUSCO (
       domain_split_fasta.euks,
       'genome',          // busco mode (choice of: genome, proteins, or transcriptome)
       busco_db_lineage,  // busco lineages file - downloads if not set
       ch_busco_db,
       [],
       busco_clean
    )

    emit:
    genome_evaluation = CHECKM2_PREDICT.out.checkm2_tsv  // channel: [ val(meta), path(tsv) ]
    stats_versions    = CHECKM2_PREDICT.out.versions_checkm2_predict

}
