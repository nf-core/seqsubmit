/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { GENOME_UPLOAD          } from '../modules/local/genome_upload'
include { ENA_WEBIN_CLI          } from '../modules/local/ena_webin_cli'

include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap       } from 'plugin/nf-schema'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

// include { CATPACK_PREPARE } from '../modules/nf-core/catpack/prepare/main'
// include { CATPACK_DOWNLOAD } from '../modules/nf-core/catpack/download/main'
// include { CATPACK_ADDNAMES } from '../modules/nf-core/catpack/addnames/main'
// include { CATPACK_BINS } from '../modules/nf-core/catpack/bins/main'
// include { CATPACK_SUMMARISE } from '../modules/nf-core/catpack/summarise/main'
// include { UNTAR } from '../modules/nf-core/untar/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow GENOMESUBMIT {

    take:
    ch_samplesheet // channel: samplesheet read in from --input
    mags_or_bins_flag

    main:

    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()

    // Create channel with meta and fasta
    ch_mags = ch_samplesheet.map { row -> [row[0], file(row[1])] }

    // adapted from:
    // - https://github.com/nf-core/mag/blob/b0bc5cae64fdd7fa6aec76f270b2daf7882ed84b/subworkflows/local/catpack/main.nf#L15
    // - https://github.com/nf-core/seqsubmit/pull/19/files

    branched = ch_samplesheet.branch { row_items ->
        def lineage = row_items[16]
        def check_lineage_missing = (!lineage || lineage == [])
        incomplete: check_lineage_missing
        complete: !check_lineage_missing
    }

    // Download catpack database if any lineage values are missing & no db path provided
    // if (params.cat_db_path & file(params.cat_db_path).exists()) {
    //     if (params.cat_db_path.endsWith('.tar.gz')) {
    //         UNTAR([[id: 'cat_db'], file(params.cat_db, checkIfExists: true)])
    //         ch_versions = ch_versions.mix(UNTAR.out.versions)

    //         ch_cat_db_dir = UNTAR.out.untar
    //     }
    //     else {
    //         ch_cat_db_dir = Channel.fromPath(params.cat_db, checkIfExists: true, type: 'dir')
    //             .map { dir -> [[id: 'cat_db'], dir] }
    //             .first()
    //     }

    //     ch_cat_db = ch_cat_db_dir.multiMap { meta, dir ->
    //         db: [meta, file(dir / 'db', checkIfExists: true)]
    //         taxonomy: [meta, file(dir / 'tax', checkIfExists: true)]
    //     }
    // }
    // else {
    //     CATPACK_DOWNLOAD([[id: 'cat_db_nr'], 'nr'])
    //     ch_versions = ch_versions.mix(CATPACK_DOWNLOAD.out.versions)

    //     CATPACK_PREPARE(
    //         CATPACK_DOWNLOAD.out.fasta,
    //         CATPACK_DOWNLOAD.out.names.map { _meta, names -> names },
    //         CATPACK_DOWNLOAD.out.nodes.map { _meta, nodes -> nodes },
    //         CATPACK_DOWNLOAD.out.acc2tax.map { _meta, acc2tax -> acc2tax },
    //     )
    //     ch_versions = ch_versions.mix(CATPACK_PREPARE.out.versions)
    //     ch_cat_db = CATPACK_PREPARE.out
    // }

    // CATPACK_BINS(
    //     ch_bins,
    //     ch_cat_db.db,
    //     ch_cat_db.taxonomy,
    //     [[:], []],
    //     [[:], []],
    //     '.fa',
    // )
    // ch_versions = ch_versions.mix(CATPACK_BINS.out.versions)

    // CATPACK_ADDNAMES(CATPACK_BINS.out.bin2classification, ch_cat_db.taxonomy)
    // ch_versions = ch_versions.mix(CATPACK_ADDNAMES.out.versions)

    // bin_summary = CATPACK_ADDNAMES.out.txt
    //     .map { _meta, summary -> summary }
    //     .collectFile(
    //         name: 'bat_summary.tsv',
    //         storeDir: "${params.outdir}/Taxonomy/CAT/",
    //         keepHeader: true,
    //     )

    // if (!params.cat_allow_unofficial_lineages) {
    //     CATPACK_SUMMARISE(CATPACK_ADDNAMES.out.txt, [[:], []])
    //     ch_versions = ch_versions.mix(CATPACK_SUMMARISE.out.versions)
    // }

    // CHECKM2_PREDICT(
    //     branched.incomplete.map { row ->
    //         [row[0], file(row[1])]
    //     },
    //     ch_check2_db,
    // )


    // checkm2_ver = CHECKM2_PREDICT.out.versions
    //     .map { yml ->
    //         yml.readLines()[1].split(': ')[1]
    //     }
    //     .map { ver -> "CheckM2_v" + ver }


    // // Join CheckM2 results with incomplete samples and fill in completeness/contamination
    // ch_checkm2_filled = CHECKM2_PREDICT.out.checkm2_tsv
    //     .map { meta, tsv ->
    //         def rows = tsv.splitCsv(sep: '\t', header: true)
    //         // CheckM2 output has one row per genome, extract first row
    //         def row = rows[0]
    //         [meta.id, row.Completeness, row.Contamination]
    //     }
    //     .combine(checkm2_ver)
    //     .cross(branched.incomplete.map { row -> [row[0].id, row] })
    //     .map { checkm2_result, incomplete_row ->
    //         def id = checkm2_result[0]
    //         def completeness = checkm2_result[1]
    //         def contamination = checkm2_result[2]
    //         def tool_ver = checkm2_result[3]
    //         def row = incomplete_row[1]

    //         // Fill in col 7 (completeness) and col 8 (contamination)
    //         row[6] = tool_ver
    //         row[7] = completeness
    //         row[8] = contamination

    //         row
    //     }

    // Combine filled incomplete samples with complete samples
    // ch_samplesheet = branched.complete.mix(ch_checkm2_filled)

    // Create TSV with metadata fields
    ch_remaining_tsv = ch_samplesheet
        .map { row ->
            def cleanRow = row.collect { item ->
                item instanceof List && item.isEmpty() ? '' : item.toString()
            }

            // Parse the genome_name column (index 0) to extract just the ID
            if (cleanRow.size() > 0 && cleanRow[0].contains('[id:') && cleanRow[0].contains(']')) {
                // Extract the ID from [id:lachnospiraceae] format
                def match = cleanRow[0] =~ /\[id:([^\]]+)\]/
                if (match) {
                    cleanRow[0] = match[0][1]
                }
            }

            // Parse the genome_path column (index 1), to show path to file in current directory
            if (cleanRow.size() > 1 && cleanRow[1].contains('/')) {
                cleanRow[1] = file(cleanRow[1]).name
            }

            cleanRow.join('\t')
        }
        .collectFile(
            name: 'submission_metadata.tsv',
            newLine: true,
            seed: {
                def headers = [
                    'genome_name', 'genome_path', 'accessions',
                    'assembly_software', 'binning_software', 'binning_parameters',
                    'stats_generation_software', 'completeness', 'contamination',
                    'genome_coverage', 'metagenome', 'co-assembly', 'broad_environment',
                    'local_environment', 'environmental_medium', 'rRNA_presence', 'NCBI_lineage'
                ]
                headers.join('\t')
            }
        )

    ch_mags_collected = ch_mags
        .map { meta, file -> file }
        .collect()
        .map { files ->
            [
                [id: 'all_files'],
                files
            ]
        }

    GENOME_UPLOAD(
        ch_mags_collected,
        ch_remaining_tsv.first(),
        mags_or_bins_flag
    )
    ch_versions = ch_versions.mix( GENOME_UPLOAD.out.versions )

    manifests_ch = GENOME_UPLOAD.out.manifests.flatten()
        .map { manifest ->
            def prefix = manifest.name.replaceAll(/_\d+\.manifest$/, '')
            def meta = [id: prefix]
            [ meta, manifest ]
    }
    combined_ch = ch_mags.join(manifests_ch)

    ENA_WEBIN_CLI( combined_ch )
    ch_versions = ch_versions.mix( ENA_WEBIN_CLI.out.versions.first() )

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_'  +  'seqsubmit_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }


    //
    // MODULE: MultiQC
    //
    ch_multiqc_config        = Channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        Channel.fromPath(params.multiqc_config, checkIfExists: true) :
        Channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        Channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        Channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        [],
        []
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]

}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
