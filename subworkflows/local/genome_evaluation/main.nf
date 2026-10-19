//
// Subworkflow that calculates completeness and contamination for genome
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { EUKCC_SINGLE             } from '../../../modules/local/eukcc/single/main'

include { BUSCO_BUSCO              } from '../../../modules/nf-core/busco/busco/main'
include { CHECKM2_DATABASEDOWNLOAD } from '../../../modules/nf-core/checkm2/databasedownload/main'
include { CHECKM2_PREDICT          } from '../../../modules/nf-core/checkm2/predict/main'
include { UNTAR as DB_UNTAR        } from '../../../modules/nf-core/untar/main'
include { GUNZIP as GUNZIP_FASTA   } from '../../../modules/nf-core/gunzip/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOME_EVALUATION {

    take:
    ch_fasta                     // channel: [ val(meta), path(fasta) ]
    ch_checkm2_db                // val: path to local CheckM2 database or null to trigger automatic download
    ch_checkm2_db_download_id    // val: CheckM2 database Zenodo download ID
    busco_db_lineage             // val: lineage for checking against, default: auto_euk
    busco_db                     // val: BUSCO database - local directory or .tar.gz/.tgz archive (path or URL), or null to download
    busco_clean                  // boolean: clean intermediate busco files
    eukaryotic_completeness_tool // val: busco or eukcc
    eukcc_db                     // val: EukCC database - local directory or .tar.gz/.tgz archive (path or URL)

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
        ch_checkm2_db_ready = channel.value([[id: 'checkm2_db'], file(ch_checkm2_db, checkIfExists: true)])
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

    // Databases for eukaryotes can be given as a directory or as a .tar.gz/.tgz archive (local path or URL).
    // Archives are extracted with a single DB_UNTAR step, only if there is at least one eukaryotic genome.
    // BUSCO database directory is expected to have the structure `<busco_db>/lineages/<taxa>_odb(10|12)`
    def busco_db_file = (eukaryotic_completeness_tool == 'busco' && busco_db) ? file(busco_db, checkIfExists: true) : null
    def eukcc_db_file = eukcc_db ? file(eukcc_db, checkIfExists: true) : null

    ch_db_archives = domain_split_fasta.euks
        .first()
        .flatMap { _meta, _fasta ->
            [
                [[id: 'busco_db'], busco_db_file],
                [[id: 'eukcc_db'], eukcc_db_file]
            ].findAll { _db_meta, db -> isArchive(db) }
        }

    DB_UNTAR ( ch_db_archives )

    if (eukaryotic_completeness_tool == 'busco') {
        // Without a database BUSCO downloads the lineages itself
        def ch_busco_db = busco_db_file
            ? prepareDatabase(busco_db_file, 'busco_db', DB_UNTAR.out.untar).map { _db_meta, db -> db }
            : []

        // Genome evaluation with BUSCO

        BUSCO_BUSCO (
           domain_split_fasta.euks,
           'genome',          // busco mode (choice of: genome, proteins, or transcriptome)
           busco_db_lineage,  // busco lineages file - downloads if not set
           ch_busco_db,
           [],
           busco_clean
        )
    }

    // Run EukCC for completeness and contamination of eukaryotes
    // Database is required only when there is at least one eukaryotic genome
    def eukcc_database = eukcc_db_file
        ? prepareDatabase(eukcc_db_file, 'eukcc_db', DB_UNTAR.out.untar)
        : domain_split_fasta.euks.first().map { _meta, _fasta ->
            error("Eukaryotic genomes were found, but --eukcc_db is not provided. Please provide the EukCC database.")
        }

    GUNZIP_FASTA ( domain_split_fasta.euks )

    EUKCC_SINGLE (
       GUNZIP_FASTA.out.gunzip,
       eukcc_database
    )

    // ------ Combine completeness and contamination from both tools into one channel

    // Software name with version, e.g. checkm2_v1.0.2, assigned per tool
    def checkm2_software = CHECKM2_PREDICT.out.versions_checkm2_predict
        .map { _process_name, tool_name, version -> "${tool_name}_v${version}" }
        .first()
    def eukcc_software = EUKCC_SINGLE.out.versions_eukcc
        .map { _process_name, tool_name, version -> "${tool_name}_v${version}" }
        .first()

    ch_prok_stats = CHECKM2_PREDICT.out.checkm2_tsv
        .combine(checkm2_software)
        .map { meta, table, software -> parseStatsTable(meta, table, software) }

    ch_euk_stats = EUKCC_SINGLE.out.eukcc_tsv
        .combine(eukcc_software)
        .map { meta, table, software -> parseStatsTable(meta, table, software) }

    emit:
    stats = ch_prok_stats.mix(ch_euk_stats)  // channel: [ val(meta), val(completeness), val(contamination), val(stats_generation_software) ]

}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// True if the database is a compressed tar archive that has to be extracted before use
//
def isArchive(db) {
    return db && (db.name.endsWith('.tar.gz') || db.name.endsWith('.tgz'))
}

//
// Return a value channel [ val(meta), path(db_dir) ] with a ready-to-use database:
// - archive (.tar.gz/.tgz, local or URL): the matching DB_UNTAR output, selected by meta.id
// - directory: used as is
// Anything else (single uncompressed file, remote directory) is an error
//
def prepareDatabase(db, db_id, ch_untarred) {
    if (isArchive(db)) {
        return ch_untarred
            .filter { db_meta, _dir -> db_meta.id == db_id }
            .first()
    }
    if (db.isDirectory()) {
        return channel.value([[id: db_id], db])
    }
    error("Database '${db}' for ${db_id} must be a local directory or a .tar.gz/.tgz archive (local path or URL)")
}

//
// Read completeness and contamination from a CheckM2 quality_report.tsv or EukCC eukcc.tsv.
// Both are tab-separated with a header and genome name, completeness, contamination as first three columns.
// Empty or header-only tables (-stub mode, EukCC exit codes 201/204) give null values.
//
def parseStatsTable(meta, table, software) {
    def lines  = table.readLines()
    def values = lines.size() > 1 ? lines[1].split('\t') : null
    return [
        meta,
        values ? values[1] : null,
        values ? values[2] : null,
        software
    ]
}
