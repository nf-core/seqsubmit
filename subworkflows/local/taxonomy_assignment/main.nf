//
// Subworkflow that assigns NCBI taxonomy to genomes without NCBI_lineage, using CAT_pack (default) or GTDB-Tk
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { RENAME_FASTA_FOR_CATPACK      } from '../../../modules/local/rename_fasta_for_catpack'

include { GTDBTK_CLASSIFYWF             } from '../../../modules/nf-core/gtdbtk/classifywf/main'
include { GTDBTK_GTDBTONCBIMAJORITYVOTE } from '../../../modules/nf-core/gtdbtk/gtdbtoncbimajorityvote/main'
include { UNTAR as GTDBTK_DB_UNTAR      } from '../../../modules/nf-core/untar/main'

include { FASTA_CLASSIFY_CATPACK        } from '../../nf-core/fasta_classify_catpack/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow TAXONOMY_ASSIGNMENT {

    take:
    ch_fasta               // channel: [ val(meta), path(fasta) ] - genomes without NCBI_lineage
    taxonomy_tool          // val: catpack or gtdbtk
    cat_db                 // val: CAT_pack database - local directory or .tar.gz archive, or null to download
    gtdbtk_db              // val: GTDB-Tk database - local directory or .tar.gz/.tgz archive (path or URL)
    gtdbtk_ar53_metadata   // val: GTDB archaeal metadata table (ar53_metadata_r*.tsv.gz) for the GTDB -> NCBI conversion
    gtdbtk_bac120_metadata // val: GTDB bacterial metadata table (bac120_metadata_r*.tsv.gz) for the GTDB -> NCBI conversion

    main:

    // Change extension for all files requiring taxonomy to .fasta (and decompress them):
    // CAT_pack requires the bin suffix as input, GTDB-Tk requires a single --extension for all genomes
    RENAME_FASTA_FOR_CATPACK ( ch_fasta )

    def ch_lineage
    if (taxonomy_tool == 'gtdbtk') {

        // All genomes are classified in one GTDB-Tk job.
        // GTDB-Tk names genomes by file name without extension, so file names must be unique.
        def ch_gtdbtk_input = RENAME_FASTA_FOR_CATPACK.out.renamed_fasta
            .map { _meta, fasta -> fasta }
            .collect()
            .map { fastas ->
                def duplicated = fastas.countBy { fasta -> fasta.baseName }.findAll { _genome_id, count -> count > 1 }.keySet()
                if (duplicated) {
                    error("GTDB-Tk classifies all genomes in one run, so FASTA file names must be unique. Duplicated names: ${duplicated.join(', ')}")
                }
                [ [id: 'gtdbtk'], fastas ]
            }

        // Database is required only when there is at least one genome to classify.
        // An archive is extracted with GTDBTK_DB_UNTAR, a directory is used as is.
        def gtdbtk_db_file = gtdbtk_db ? file(gtdbtk_db, checkIfExists: true) : null
        def ch_gtdbtk_db
        if (!gtdbtk_db_file) {
            ch_gtdbtk_db = ch_gtdbtk_input.map { _meta, _fastas ->
                error("Genomes without NCBI_lineage were found and --taxonomy_tool is 'gtdbtk', but --gtdbtk_db is not provided. Please provide the GTDB-Tk database.")
            }
        } else if (gtdbtk_db_file.name.endsWith('.tar.gz') || gtdbtk_db_file.name.endsWith('.tgz')) {
            GTDBTK_DB_UNTAR (
                ch_gtdbtk_input.map { _meta, _fastas -> [ [id: 'gtdbtk_db'], gtdbtk_db_file ] }
            )
            ch_gtdbtk_db = GTDBTK_DB_UNTAR.out.untar.first()
        } else if (gtdbtk_db_file.isDirectory()) {
            ch_gtdbtk_db = channel.value([ [id: 'gtdbtk_db'], gtdbtk_db_file ])
        } else {
            error("GTDB-Tk database '${gtdbtk_db}' must be a local directory or a .tar.gz/.tgz archive (local path or URL)")
        }

        GTDBTK_CLASSIFYWF (
            ch_gtdbtk_input,
            ch_gtdbtk_db,
            false            // use_pplacer_scratch_dir
        )

        GTDBTK_GTDBTONCBIMAJORITYVOTE (
            GTDBTK_CLASSIFYWF.out.gtdb_outdir.map { meta, outdir -> [ meta, outdir, meta.id ] },
            [ [id: 'ar53'], file(gtdbtk_ar53_metadata, checkIfExists: true) ],
            [ [id: 'bac120'], file(gtdbtk_bac120_metadata, checkIfExists: true) ]
        )

        // [ genome_id: lineage ] for every genome in the GTDB-Tk -> NCBI table
        def ch_gtdbtk_lineages = GTDBTK_GTDBTONCBIMAJORITYVOTE.out.tsv
            .map { _meta, tsv -> parseMajorityVoteTable(tsv) }

        // Link GTDB-Tk genome IDs (file name without extension) back to meta.
        // Genomes that GTDB-Tk could not classify (e.g. eukaryotes or genomes without marker genes)
        // are missing from the table. In -stub mode the table is empty, so the lineage is null.
        ch_lineage = RENAME_FASTA_FOR_CATPACK.out.renamed_fasta
            .combine(ch_gtdbtk_lineages)
            .map { meta, fasta, lineages ->
                def genome_id = fasta.baseName
                def lineage   = lineages[genome_id]
                if (lineage == null && !workflow.stubRun) {
                    error("GTDB-Tk could not assign taxonomy to genome '${meta.id}' (${genome_id}). GTDB-Tk classifies only bacteria and archaea: provide NCBI_lineage in the samplesheet or use --taxonomy_tool catpack.")
                }
                [ meta, lineage ]
            }

    } else {

        // build input structures for CAT_DB depending on what provided as input
        def cat_db_input = cat_db
            ? channel.of( [['id': 'CAT_DB'], file(cat_db)] )
            : channel.empty()

        def cat_db_download_id = "nr"  // NCBI non-redundant protein database identifier
        def cat_db_id_input = cat_db
            ? channel.empty()
            : channel.of( [['id': 'CAT_DB_id'], cat_db_download_id] )

        FASTA_CLASSIFY_CATPACK (
            RENAME_FASTA_FOR_CATPACK.out.renamed_fasta,  // ch_bins
            channel.empty(),                             // ch_contigs - empty because we classify bins, not contigs
            cat_db_input,
            cat_db_id_input,
            false,                                       // disable summary generation
            '.fasta'                                     // bin_suffix - the suffix of the renamed fasta files
        )

        ch_lineage = FASTA_CLASSIFY_CATPACK.out.bat_classification
            .map { meta, taxa_tsv ->
                def lines = taxa_tsv.readLines()
                // support for empty taxonomy files required for -stub mode
                // skip header and take 4th column from table corresponding to lineage
                [ meta, lines ? lines[1].split('\t')[3] : null ]
            }
    }

    emit:
    lineage = ch_lineage  // channel: [ val(meta), val(NCBI_lineage) ] - lineage is null in -stub mode
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Read gtdb_to_ncbi_majority_vote.py output into a [ genome_id: ncbi_lineage ] map.
// Columns are found by header name: 'Genome ID' and 'Majority vote NCBI classification'.
//
def parseMajorityVoteTable(tsv) {
    def lines = tsv.readLines().findAll { line -> line.trim() }
    if (!lines) {
        return [:]
    }
    def header      = lines[0].split('\t')*.trim()
    def id_index    = header.findIndexOf { column -> column.equalsIgnoreCase('Genome ID') || column == 'user_genome' }
    def ncbi_index  = header.findIndexOf { column -> column.toLowerCase().contains('ncbi classification') }
    if (id_index < 0 || ncbi_index < 0) {
        error("Unexpected header in GTDB-Tk majority vote table ${tsv.name}: ${lines[0]}")
    }
    return lines.drop(1).collectEntries { line ->
        def fields = line.split('\t', -1)
        [ (fields[id_index].trim()): fields[ncbi_index].trim() ]
    }
}
