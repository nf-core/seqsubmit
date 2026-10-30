//
// Subworkflow that calculates completeness and contamination for eukaryotic genomes
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { EUKCC_SINGLE             } from '../../../modules/local/eukcc/single/main'

include { BUSCO_BUSCO              } from '../../../modules/nf-core/busco/busco/main'
include { UNTAR as DB_UNTAR        } from '../../../modules/nf-core/untar/main'
include { GUNZIP as GUNZIP_FASTA   } from '../../../modules/nf-core/gunzip/main'

include { parseStatsTable; mergeSoftware; isNotAssigned } from '../utils_nfcore_seqsubmit_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow EUKARYOTIC_GENOME_EVALUATION {

    take:
    ch_fasta                     // channel: [ val(meta), path(fasta) ] - eukaryotic genomes only
    busco_db_lineage             // val: lineage for checking against, default: auto_euk
    busco_db                     // val: BUSCO database - local directory or .tar.gz/.tgz archive (path or URL), or null to download
    busco_clean                  // boolean: clean intermediate busco files
    eukaryotic_completeness_tool // val: busco or eukcc
    eukcc_db                     // val: EukCC database - local directory or .tar.gz/.tgz archive (path or URL)

    main:

    // Contamination can only be calculated by EukCC. If contamination is already given in the samplesheet
    // and BUSCO calculates completeness, EukCC is skipped for that genome.
    // Without BUSCO, EukCC runs as usual for completeness and contamination from the samplesheet is kept.
    euks_split = ch_fasta
        .branch { meta, _fasta ->
            busco_only: eukaryotic_completeness_tool == 'busco' && meta.contamination != null
            eukcc:      true
        }

    // Databases for eukaryotes can be given as a directory or as a .tar.gz/.tgz archive (local path or URL).
    // Archives are extracted with a single DB_UNTAR step, only if there is at least one genome that needs the tool.
    // BUSCO database directory is expected to have the structure `<busco_db>/lineages/<taxa>_odb(10|12)`
    def busco_db_file = (eukaryotic_completeness_tool == 'busco' && busco_db) ? file(busco_db, checkIfExists: true) : null
    def eukcc_db_file = eukcc_db ? file(eukcc_db, checkIfExists: true) : null

    ch_db_archives = ch_fasta
        .first()
        .filter { _meta, _fasta -> isArchive(busco_db_file) }
        .map { _meta, _fasta -> [[id: 'busco_db'], busco_db_file] }
        .mix(
            euks_split.eukcc
                .first()
                .filter { _meta, _fasta -> isArchive(eukcc_db_file) }
                .map { _meta, _fasta -> [[id: 'eukcc_db'], eukcc_db_file] }
        )

    DB_UNTAR ( ch_db_archives )

    if (eukaryotic_completeness_tool == 'busco') {
        // Without a database BUSCO downloads the lineages itself
        def ch_busco_db = busco_db_file
            ? prepareDatabase(busco_db_file, 'busco_db', DB_UNTAR.out.untar).map { _db_meta, db -> db }
            : []

        // Genome evaluation with BUSCO

        BUSCO_BUSCO (
           ch_fasta,
           'genome',          // busco mode (choice of: genome, proteins, or transcriptome)
           busco_db_lineage,  // busco lineages file - downloads if not set
           ch_busco_db,
           [],
           busco_clean
        )
    }

    // Run EukCC for completeness and contamination of eukaryotes
    // Database is required only when there is at least one eukaryotic genome to run EukCC on
    def eukcc_database = eukcc_db_file
        ? prepareDatabase(eukcc_db_file, 'eukcc_db', DB_UNTAR.out.untar)
        : euks_split.eukcc.first().map { _meta, _fasta ->
            error("Eukaryotic genomes were found, but --eukcc_db is not provided. Please provide the EukCC database.")
        }

    GUNZIP_FASTA ( euks_split.eukcc )

    EUKCC_SINGLE (
       GUNZIP_FASTA.out.gunzip,
       eukcc_database
    )

    // ------ Combine completeness and contamination from all tools into one channel
    // Tools are listed in stats_generation_software separated by ';'.
    // If stats_generation_software is given in the samplesheet, launched tools are appended to it.

    // Software name with version, e.g. eukcc_v2.2.0, assigned per tool
    def eukcc_software = EUKCC_SINGLE.out.versions_eukcc
        .map { _process_name, tool_name, version -> "${tool_name}_v${version}" }
        .first()

    // [ meta, completeness, contamination, software ], contamination from the samplesheet is kept if present
    ch_eukcc_stats = EUKCC_SINGLE.out.eukcc_tsv
        .combine(eukcc_software)
        .map { meta, table, software -> parseStatsTable(meta, table, software) }
        .map { meta, completeness, contamination, software ->
            [ meta, completeness, meta.contamination != null ? meta.contamination : contamination, software ]
        }

    if (eukaryotic_completeness_tool == 'busco') {
        // With BUSCO activated, completeness is taken from BUSCO and contamination from EukCC or samplesheet
        def busco_software = BUSCO_BUSCO.out.versions_busco
            .map { _process_name, tool_name, version -> "${tool_name}_v${version}" }
            .first()
        def ch_busco_completeness = BUSCO_BUSCO.out.short_summaries_json
            .map { meta, summaries -> [ meta, parseBuscoCompleteness(summaries) ] }

        // BUSCO short summary is optional (no genes found) and EukCC is skipped for busco_only genomes -
        // remainder keeps every eukaryotic genome, missing results are null
        ch_euk_stats = ch_fasta
            .map { meta, _fasta -> [ meta, true ] }
            .join(ch_busco_completeness, remainder: true)
            .join(ch_eukcc_stats.map { meta, completeness, contamination, software -> [ meta, [completeness, contamination, software] ] }, remainder: true)
            .combine(busco_software)
            .map { meta, _is_euk, busco_completeness, eukcc_stats, busco_sw ->
                def contamination = eukcc_stats ? eukcc_stats[1] : meta.contamination
                def tools         = [ busco_sw, eukcc_stats ? eukcc_stats[2] : null ]
                [ meta, busco_completeness, contamination, mergeSoftware(meta.stats_generation_software, tools) ]
            }
    } else {
        ch_euk_stats = ch_eukcc_stats
            .map { meta, completeness, contamination, software ->
                [ meta, completeness, contamination, mergeSoftware(meta.stats_generation_software, [software]) ]
            }
    }

    // ------ Filter out genomes without completeness or contamination
    // EukCC reports NA when it cannot place a genome, BUSCO summary is missing when no genes are found.
    // Values are not checked in -stub mode, where empty tool outputs give null values.
    ch_euk_stats_branched = ch_euk_stats
        .branch { _meta, completeness, contamination, _software ->
            not_assigned: !workflow.stubRun && [completeness, contamination].any { value -> isNotAssigned(value) }
            assigned: true
        }

    ch_euk_stats_branched.not_assigned
        .map { meta, completeness, contamination, software ->
            log.warn("Genome '${meta.id}' is excluded from submission: ${software} returned completeness='${completeness}', contamination='${contamination}'")
            "${meta.id}\t${completeness}\t${contamination}\t${software}"
        }
        .collectFile(
            name: "${params.outdir}/${params.mode}/not_assigned_quality_genomes.tsv",
            newLine: true,
            seed: "sample\tcompleteness\tcontamination\tstats_generation_software\n"
        )

    emit:
    stats        = ch_euk_stats_branched.assigned      // channel: [ val(meta), val(completeness), val(contamination), val(stats_generation_software) ]
    not_assigned = ch_euk_stats_branched.not_assigned  // channel: [ val(meta), val(completeness), val(contamination), val(stats_generation_software) ]

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
// Read completeness ([results][Complete percentage]) from BUSCO short_summary json.
// With auto-lineage BUSCO writes a generic and a specific summary - the specific lineage is preferred.
//
def parseBuscoCompleteness(summaries) {
    def summary_files = summaries instanceof List ? summaries : [summaries]
    def summary = summary_files.find { json -> json.name.startsWith('short_summary.specific.') } ?: summary_files[0]
    def completeness = new groovy.json.JsonSlurper().parseText(summary.text)?.results?.get('Complete percentage')
    return completeness != null ? completeness.toString() : null
}
