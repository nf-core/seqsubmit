/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { GENOME_UPLOAD          } from '../modules/local/genome_upload'
include { ENA_WEBIN_CLI          } from '../modules/local/ena_webin_cli'
include { CALCULATE_COVERAGE     } from '../modules/local/calculate_coverage'

include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap       } from 'plugin/nf-schema'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

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
    ch_mags = ch_samplesheet
        .map { row ->
            [ row[0], file(row[1]) ]
        }

    // Check for missing genome_coverage and split samples
    ch_samplesheet
        .branch { row ->
            // genome_coverage is at index 9 (10th column in the row)
            def coverage = row[9]
            has_coverage: coverage != null && coverage != '' && coverage != []
            needs_coverage: coverage == null || coverage == '' || coverage == []
        }
        .set { ch_coverage_split }

    // For samples missing coverage, calculate it
    ch_samples_needing_coverage = ch_coverage_split.needs_coverage
        .map { row ->
            def sample_id = row[0]
            // Extract just the sample ID if it's in [id:xxx] format
            if (sample_id instanceof Map) {
                sample_id = sample_id.id
            } else if (sample_id.toString().contains('[id:')) {
                def match = sample_id.toString() =~ /\[id:([^\]]+)\]/
                if (match) {
                    sample_id = match[0][1]
                }
            }
            def meta = [id: sample_id]
            def fasta_file = file(row[1])
            log.warn "Sample ${sample_id} is missing genome_coverage - calculating coverage using CALCULATE_COVERAGE module"
            [ meta, fasta_file, row ]  // Pass the full row along for later merging
        }

    // Calculate coverage for samples that need it
    CALCULATE_COVERAGE(
        ch_samples_needing_coverage.map { meta, fasta, row -> [meta, fasta] }
    )
    ch_versions = ch_versions.mix( CALCULATE_COVERAGE.out.versions.first() )

    // Merge calculated coverage back into the row data
    ch_calculated_coverage = ch_samples_needing_coverage
        .map { meta, fasta, row -> [meta.id, row] }
        .join(
            CALCULATE_COVERAGE.out.coverage.map { meta, cov -> [meta.id, cov] }
        )
        .map { sample_id, row, calculated_cov ->
            // Update the coverage value in the row (index 9)
            row[9] = calculated_cov
            row
        }

    // Combine samples with original coverage and calculated coverage
    ch_all_samples_with_coverage = ch_coverage_split.has_coverage
        .mix(ch_calculated_coverage)

    // Create TSV with metadata fields (now with coverage values for all samples)
    ch_remaining_tsv = ch_all_samples_with_coverage
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
