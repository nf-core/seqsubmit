/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { COVERM_CONTIG                         } from '../modules/nf-core/coverm/contig/main'
include { CREATE_ASSEMBLY_METADATA_CSV          } from '../modules/local/create_assembly_metadata_csv/main'
include { GENERATE_ASSEMBLY_MANIFEST            } from '../modules/local/generate_assembly_manifest/main'
include { REGISTERSTUDY                         } from '../modules/local/registerstudy/main'
include { ENA_WEBIN_CLI_WRAPPER as SUBMIT       } from '../modules/local/ena_webin_cli_wrapper'

include { FIND_CONCATENATE as CONCAT_METADATA   } from '../modules/nf-core/find/concatenate/main'
include { FIND_CONCATENATE as CONCAT_ACCESSIONS } from '../modules/nf-core/find/concatenate/main'
include { MULTIQC                               } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap                      } from 'plugin/nf-schema'

include { paramsSummaryMultiqc                  } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML                } from '../subworkflows/nf-core/utils_nfcore_pipeline'

include { FASTA_VALIDATION                      } from '../subworkflows/local/fasta_validation'
include { methodsDescriptionText                } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN THE WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow ASSEMBLYSUBMIT {

    take:
    ch_samplesheet       // channel: samplesheet read in from --input
    multiqc_config
    multiqc_logo
    multiqc_methods_description
    outdir
    submission_study     // val: accession of the study to submit to (optional)
    study_metadata       // val: path to study metadata file for study creation (used if no submission_study provided)
    upload_tpa           // val: upload as TPA (Third Party Annotation)
    test_upload          // val: true for test upload mode
    webincli_mode        // val: either 'validate' or 'submit' to specify WebinCLI mode of operation
    is_private           // val: fetch metadata from private/public account
    hold_data_private    // val: keep submitted data private until given date

    main:

    def ch_versions = channel.empty()
    def ch_multiqc_files = channel.empty()

    // Create assembly channel with proper metadata structure
    assembly_fasta = ch_samplesheet
        .map { row ->
            def meta = [
                id: row[0].id,
                single_end: row[3] ? false : true,
                coverage: row[4] ?: null,
                run_accession: row[5],
                assembler: row[6],
                assembler_version: row[7]
            ]
            [meta, file(row[1])]
        }

    reads_fastq = ch_samplesheet
        .filter { row -> row[2] && row[2] != "" } // Check if fastq_1 exists and is not empty
        .map { row ->
            def meta = [
                id: row[0].id,
                single_end: row[3] ? false : true,
                coverage: row[4] ?: null,
                run_accession: row[5],
                assembler: row[6],
                assembler_version: row[7]
            ]

            if (row[3] && row[3] != "") {
                // If paired end reads
                [meta, [file(row[2]), file(row[3])]]
            } else {
                // If single end
                [meta, file(row[2])]
            }
        }

    // --------- Check fasta files are properly formatted and filter out files with less than 2 contigs
    FASTA_VALIDATION (
        assembly_fasta
    )

    // For assemblies without coverage, calculate coverage with CoverM
    FASTA_VALIDATION.out.valid_fastas
        .filter { meta, _fasta -> meta.coverage == null }
        .join(reads_fastq)
        .multiMap { meta, fasta, fastq ->
            assembly: [ meta, fasta ]
            reads: [ meta, fastq ]
        }
        .set { coverm_input }

    COVERM_CONTIG (
        coverm_input.reads,
        coverm_input.assembly,
        false, // bam_input
        false, // interleaved
        false  // enable_bam_output
    )

    // Calculate average coverage using splitCsv operator
    average_coverage_ch = COVERM_CONTIG.out.coverage
        .splitCsv(sep: '\t', skip: 1)
        .map { meta, row ->
            [meta, row[1] as Double]
        }
        .groupTuple()
        .map { meta, coverages ->
            def average = coverages.sum() / coverages.size()
            [meta, average]
        }

    // Update metadata with calculated coverage
    FASTA_VALIDATION.out.valid_fastas
        .filter { meta, _fasta -> meta.coverage == null }
        .join( average_coverage_ch )
        .map { meta, fasta, avg_coverage ->
            def updated_meta = meta.clone()
            updated_meta.coverage = avg_coverage
            [updated_meta, fasta]
        }
        .set { assemblies_with_added_cov_ch }

    // Combine assemblies with updated metadata (for samples that had coverage calculated)
    // and assemblies that already had coverage
    assemblies_with_coverage = FASTA_VALIDATION.out.valid_fastas
        .filter { meta, _fasta -> meta.coverage != null }
        .mix( assemblies_with_added_cov_ch )

    // Create CSV with assembly metadata for manifest generation
    CREATE_ASSEMBLY_METADATA_CSV(
        assemblies_with_coverage
    )
    ch_versions = ch_versions.mix(CREATE_ASSEMBLY_METADATA_CSV.out.versions)

    // Concatenate assembly metadata CSVs into single file to publish
    CONCAT_METADATA (
        CREATE_ASSEMBLY_METADATA_CSV.out.csv.map { _meta, file -> file }.collect().map { files -> [ [id: "assemblies_metadata"], files ] },
        'true' // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    if (!submission_study && !study_metadata) {
        error("Either --submission_study or --study_metadata must be provided")
    }
    def study_accession_ch
    if (submission_study) {
        // Use provided study accession directly
        study_accession_ch = channel.of(submission_study)
    } else {
        // Register a new study using the study metadata file
        REGISTERSTUDY(
            channel.of([[id: "study"], file(study_metadata)]),
            test_upload,
            hold_data_private
        )
        ch_versions = ch_versions.mix(REGISTERSTUDY.out.versions)
        study_accession_ch = REGISTERSTUDY.out.accessions
            .map { _meta, json ->
                def data = new groovy.json.JsonSlurper().parse(json)
                data.submitted[0]?.accession
            }
    }

    // Generate assembly manifest files and submit them to ENA
    GENERATE_ASSEMBLY_MANIFEST(
        assemblies_with_coverage.join(CREATE_ASSEMBLY_METADATA_CSV.out.csv),
        study_accession_ch.first(),
        upload_tpa,
        test_upload,
        is_private
    )
    ch_versions = ch_versions.mix(GENERATE_ASSEMBLY_MANIFEST.out.versions.first())

    SUBMIT (
        assemblies_with_coverage.join(GENERATE_ASSEMBLY_MANIFEST.out.manifest),
        test_upload,
        webincli_mode,
        "genome"
    )
    ch_versions = ch_versions.mix(SUBMIT.out.versions)

    // Concatenate accessions into single file to publish
    CONCAT_ACCESSIONS (
        SUBMIT.out.accessions.map { _meta, file -> file }.collect().map { files -> [ [id: "assemblies_accessions"], files ] },
        'true' // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    //
    // Collate and save software versions
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name: 'nf_core_'  +  'seqsubmit_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    //
    // MODULE: MultiQC
    //
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    def ch_summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def ch_workflow_summary = channel.value(paramsSummaryMultiqc(ch_summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    def ch_multiqc_custom_methods_description = multiqc_methods_description
        ? file(multiqc_methods_description, checkIfExists: true)
        : file("${projectDir}/assets/methods_description_template.yml", checkIfExists: true)
    def ch_methods_description = channel.value(methodsDescriptionText(ch_multiqc_custom_methods_description))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: true))
    ch_multiqc_files = ch_multiqc_files.mix(CONCAT_ACCESSIONS.out.file_out.map{meta, file -> file})
    ch_multiqc_files = ch_multiqc_files.mix(CONCAT_METADATA.out.file_out.map{meta, file -> file})
    MULTIQC(
        ch_multiqc_files.flatten().collect().map { files ->
            [
                [id: 'seqsubmit'],
                files,
                multiqc_config
                    ? file(multiqc_config, checkIfExists: true)
                    : file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true),
                multiqc_logo ? file(multiqc_logo, checkIfExists: true) : [],
                [],
                [],
            ]
        }
    )
    emit:
    multiqc_report = MULTIQC.out.report.map { _meta, report -> [report] }.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
