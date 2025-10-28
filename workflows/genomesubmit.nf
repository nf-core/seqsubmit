/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { GENOME_UPLOAD          } from '../modules/local/genome_upload'
include { ENA_WEBIN_CLI          } from '../modules/local/ena_webin_cli'
include { COVERM_GENOME          } from '../modules/nf-core/coverm/genome/main'

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

    // For samples missing coverage, check if reads are available
    // raw_fastq1 is at index 10, raw_fastq2 is at index 11 (after adding new columns)
    ch_samples_needing_coverage = ch_coverage_split.needs_coverage
        .branch { row ->
            def sample_id = row[0]
            // Extract sample ID if in [id:xxx] format
            if (sample_id instanceof Map) {
                sample_id = sample_id.id
            } else if (sample_id.toString().contains('[id:')) {
                def match = sample_id.toString() =~ /\[id:([^\]]+)\]/
                if (match) {
                    sample_id = match[0][1]
                }
            }

            def has_fastq1 = row[10] != null && row[10] != '' && row[10] != []
            def has_fastq2 = row[11] != null && row[11] != '' && row[11] != []

            with_reads: has_fastq1  // Has at least read 1
            without_reads: true     // No reads available
        }

    // Branch 1: Samples WITH reads - use COVERM_GENOME
    ch_samples_with_reads = ch_samples_needing_coverage.with_reads
        .map { row ->
            def sample_id = row[0]
            if (sample_id instanceof Map) {
                sample_id = sample_id.id
            } else if (sample_id.toString().contains('[id:')) {
                def match = sample_id.toString() =~ /\[id:([^\]]+)\]/
                if (match) {
                    sample_id = match[0][1]
                }
            }

            def has_fastq2 = row[11] != null && row[11] != '' && row[11] != []
            def meta = [id: sample_id, single_end: !has_fastq2]
            def fasta_file = file(row[1])
            def fastq1 = file(row[10])
            def fastq2 = has_fastq2 ? file(row[11]) : []
            def reads = has_fastq2 ? [fastq1, fastq2] : [fastq1]

            log.info "Sample ${sample_id} is missing genome_coverage - calculating with CoverM using provided reads"
            [ meta, reads, fasta_file, row ]
        }

    // Run COVERM_GENOME for samples with reads
    COVERM_GENOME(
        ch_samples_with_reads.map { meta, reads, fasta, row -> [meta, reads] },
        ch_samples_with_reads.map { meta, reads, fasta, row -> [[id: 'reference'], fasta] },
        false,        // bam_input = false (we have FASTQ)
        false,        // interleaved = false
        'file'        // ref_mode = file (single FASTA per sample)
    )
    ch_versions = ch_versions.mix( COVERM_GENOME.out.versions.first() )

    // Parse CoverM TSV output to extract coverage value
    ch_coverm_results = ch_samples_with_reads
        .map { meta, reads, fasta, row -> [meta.id, row] }
        .join(
            COVERM_GENOME.out.coverage.map { meta, tsv ->
                // Parse the TSV file to extract mean coverage value
                // CoverM output format: "Genome\tSample Mean" (malformed header) or "Genome\tSample\tMean"
                // Data line: "genome_name\t25.1329"
                def coverage_value = 0.0
                def lines = tsv.text.split('\n')
                if (lines.size() > 1) {
                    // Skip header, parse data line
                    def data_line = lines[1].split('\t')
                    if (data_line.size() > 1) {
                        // The last column contains the coverage value
                        coverage_value = data_line[-1].trim() as Double
                    }
                }
                [meta.id, coverage_value]
            }
        )
        .map { sample_id, row, calculated_cov ->
            row[9] = calculated_cov
            row
        }

    // Branch 2: Samples WITHOUT reads - leave coverage empty
    ch_samples_without_reads = ch_samples_needing_coverage.without_reads
        .map { row ->
            def sample_id = row[0]
            if (sample_id instanceof Map) {
                sample_id = sample_id.id
            } else if (sample_id.toString().contains('[id:')) {
                def match = sample_id.toString() =~ /\[id:([^\]]+)\]/
                if (match) {
                    sample_id = match[0][1]
                }
            }
            log.warn "Sample ${sample_id} is missing genome_coverage and no reads provided - coverage will be empty in submission"
            // Keep coverage empty (don't modify row[9])
            row
        }

    // Combine all calculated coverage results (only CoverM results, no dummy values)
    ch_calculated_coverage = ch_coverm_results.mix(ch_samples_without_reads)

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

            // IMPORTANT: Exclude raw_fastq1 (index 10) and raw_fastq2 (index 11) from the TSV
            // genome_uploader expects: genome_name, genome_path, accessions, assembly_software,
            // binning_software, binning_parameters, stats_generation_software, completeness,
            // contamination, genome_coverage, metagenome, co-assembly, broad_environment,
            // local_environment, environmental_medium, rRNA_presence, NCBI_lineage
            def tsvRow = []
            cleanRow.eachWithIndex { item, idx ->
                // Skip indices 10 and 11 (raw_fastq1 and raw_fastq2)
                if (idx != 10 && idx != 11) {
                    tsvRow << item
                }
            }

            tsvRow.join('\t')
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
