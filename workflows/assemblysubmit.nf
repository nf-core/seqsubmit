/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { COVERM_CONTIG                         } from '../modules/nf-core/coverm/contig/main'
include { FASTAVALIDATOR                        } from '../modules/nf-core/fastavalidator/main'
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
include { methodsDescriptionText                } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN THE WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow ASSEMBLYSUBMIT {

    take:
    ch_samplesheet       // channel: samplesheet read in from --input
    submission_study     // val: accession of the study to submit to (optional)
    study_metadata       // val: path to study metadata file for study creation (used if no submission_study provided)
    upload_tpa           // val: upload as TPA (Third Party Annotation)
    test_upload          // val: true for test upload mode
    webin_cli_version    // val: WebinCLI tool version to download and use for submission
    webincli_mode        // val: either 'validate' or 'submit' to specify WebinCLI mode of operation
    outdir

    main:
    ch_versions = channel.empty()
    ch_multiqc_files = channel.empty()

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

    // Check fasta files are properly formatted
    FASTAVALIDATOR (
        assembly_fasta,
        "true" // enables number of contigs check - ENA requires more than 1 contig for an assembly submission
    )
    ch_versions = ch_versions.mix(FASTAVALIDATOR.out.versions)

    validated_fastas = assembly_fasta.join(FASTAVALIDATOR.out.success_log)
        .map { meta, fasta, _log ->
            [meta, fasta]
        }

    // For assemblies without coverage, calculate coverage with CoverM
    validated_fastas.filter { meta, _fasta -> meta.coverage == null }
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
        false  // interleaved
    )
    ch_versions = ch_versions.mix(COVERM_CONTIG.out.versions)

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
    validated_fastas
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
    assemblies_with_coverage = validated_fastas
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

    def study_accession_ch
    if (submission_study) {
        // Use provided study accession directly
        study_accession_ch = channel.of(submission_study)
    } else {
        // Register a new study using the study metadata file
        REGISTERSTUDY(
            channel.of([[id: "study"], file(study_metadata)]),
            test_upload
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
        test_upload
    )
    ch_versions = ch_versions.mix(GENERATE_ASSEMBLY_MANIFEST.out.versions.first())

    SUBMIT (
        assemblies_with_coverage.join(GENERATE_ASSEMBLY_MANIFEST.out.manifest),
        test_upload,
        webincli_mode
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
    ch_multiqc_config        = channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        channel.fromPath(params.multiqc_config, checkIfExists: true) :
        channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(CONCAT_ACCESSIONS.out.file_out.map{meta, file -> file})
    ch_multiqc_files = ch_multiqc_files.mix(CONCAT_METADATA.out.file_out.map{meta, file -> file})
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
