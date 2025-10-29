/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { GENOME_UPLOAD } from '../modules/local/genome_upload'
include { ENA_WEBIN_CLI } from '../modules/local/ena_webin_cli'

include { MULTIQC } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap } from 'plugin/nf-schema'
include { paramsSummaryMultiqc } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

include { CHECKM2_DATABASEDOWNLOAD } from '../modules/nf-core/checkm2/databasedownload/main'
include { CHECKM2_PREDICT } from '../modules/nf-core/checkm2/predict/main'

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

    branched = ch_samplesheet.branch { row ->
        def col7 = row[6]
        def col8 = row[7]
        def col9 = row[8]
        def missing = (!col7 || !col8 || !col9 || col7 == [] || col8 == [] || col9 == [])
        incomplete: missing
        complete: !missing
    }
    // Run checkM2 database download if any completeness/contamination values are provided
    CHECKM2_DATABASEDOWNLOAD(params.db_zenodo_id)

    CHECKM2_PREDICT(
        branched.incomplete.map { row ->
            [row[0], file(row[1])]
        },
        CHECKM2_DATABASEDOWNLOAD.out.database,
    )


    checkm2_ver = CHECKM2_PREDICT.out.versions
        .map { yml ->
            yml.readLines()[1].split(': ')[1]
        }
        .map { ver -> "CheckM2_v" + ver }


    // Join CheckM2 results with incomplete samples and fill in completeness/contamination
    ch_checkm2_filled = CHECKM2_PREDICT.out.checkm2_tsv
        .map { meta, tsv ->
            def rows = tsv.splitCsv(sep: '\t', header: true)
            // CheckM2 output has one row per genome, extract first row
            def row = rows[0]
            [meta.id, row.Completeness, row.Contamination]
        }
        .combine(checkm2_ver)
        .cross(branched.incomplete.map { row -> [row[0].id, row] })
        .map { checkm2_result, incomplete_row ->
            def id = checkm2_result[0]
            def completeness = checkm2_result[1]
            def contamination = checkm2_result[2]
            def tool_ver = checkm2_result[3]
            def row = incomplete_row[1]

            // Fill in col 7 (completeness) and col 8 (contamination)
            row[6] = tool_ver
            row[7] = completeness
            row[8] = contamination

            row
        }



    // Combine filled incomplete samples with complete samples
    ch_samplesheet = branched.complete.mix(ch_checkm2_filled)

    // Create channel with meta and fasta
    ch_mags = ch_samplesheet.map { row ->
        [row[0], file(row[1])]
    }

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
                    'genome_name',
                    'genome_path',
                    'accessions',
                    'assembly_software',
                    'binning_software',
                    'binning_parameters',
                    'stats_generation_software',
                    'completeness',
                    'contamination',
                    'genome_coverage',
                    'metagenome',
                    'co-assembly',
                    'broad_environment',
                    'local_environment',
                    'environmental_medium',
                    'rRNA_presence',
                    'NCBI_lineage',
                ]
                headers.join('\t')
            },
        )

    ch_mags_collected = ch_mags
        .map { meta, file -> file }
        .collect()
        .map { files ->
            [
                [id: 'all_files'],
                files,
            ]
        }

    GENOME_UPLOAD(
        ch_mags_collected,
        ch_remaining_tsv.first(),
        mags_or_bins_flag,
    )
    ch_versions = ch_versions.mix(GENOME_UPLOAD.out.versions)

    manifests_ch = GENOME_UPLOAD.out.manifests
        .flatten()
        .map { manifest ->
            def prefix = manifest.name.replaceAll(/_\d+\.manifest$/, '')
            def meta = [id: prefix]
            [meta, manifest]
        }
    combined_ch = ch_mags.join(manifests_ch)

    ENA_WEBIN_CLI(combined_ch)
    ch_versions = ch_versions.mix(ENA_WEBIN_CLI.out.versions.first())

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_' + 'seqsubmit_software_' + 'mqc_' + 'versions.yml',
            sort: true,
            newLine: true,
        )
        .set { ch_collated_versions }


    //
    // MODULE: MultiQC
    //
    ch_multiqc_config = Channel.fromPath(
        "${projectDir}/assets/multiqc_config.yml",
        checkIfExists: true
    )
    ch_multiqc_custom_config = params.multiqc_config
        ? Channel.fromPath(params.multiqc_config, checkIfExists: true)
        : Channel.empty()
    ch_multiqc_logo = params.multiqc_logo
        ? Channel.fromPath(params.multiqc_logo, checkIfExists: true)
        : Channel.empty()

    summary_params = paramsSummaryMap(
        workflow,
        parameters_schema: "nextflow_schema.json"
    )
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml')
    )
    ch_multiqc_custom_methods_description = params.multiqc_methods_description
        ? file(params.multiqc_methods_description, checkIfExists: true)
        : file("${projectDir}/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description)
    )

    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true,
        )
    )

    MULTIQC(
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        [],
        [],
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions = ch_versions // channel: [ path(versions.yml) ]
}
