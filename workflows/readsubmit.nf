/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CREATE_READS_MANIFEST              } from '../modules/local/create_reads_manifest/main'
include { ENA_WEBIN_CLI_WRAPPER as SUBMIT    } from '../modules/local/ena_webin_cli_wrapper'
include { REGISTERSTUDY                      } from '../modules/local/registerstudy/main'

include { FIND_CONCATENATE as CONCAT_ACCESSIONS } from '../modules/nf-core/find/concatenate/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN THE WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow READSUBMIT {

    take:
    ch_samplesheet       // channel: samplesheet read in from --input
    submission_study     // val: ENA study accession for all reads in this run (optional).
                         // NOTE: all samples must belong to the same study and Webin account.
                         // Submitting reads across multiple studies or Webin accounts in a
                         // single pipeline run is not supported.
    study_metadata       // val: path to study metadata file for study creation (used if no submission_study provided)
    test_upload          // val: true for test upload mode
    webincli_mode        // val: either 'validate' or 'submit' to specify WebinCLI mode of operation
    release_date         // val: keep submitted data private until given date
    center_name          // val: name of submitting institution

    main:
    def ch_multiqc_files = channel.empty()

    // --------- Create reads channel with proper metadata structure
    reads_ch = ch_samplesheet
        .map { meta, reads_1, reads_2, bam ->
            if ( bam ) {
                // Reads provided as BAM
                [meta + [single_end: true, file_type: 'bam'], bam]
            } else if ( reads_2 ) {
                // If paired end reads
                [meta + [single_end: false, file_type: 'fastq'], [reads_1, reads_2]]
            } else {
                // If single end
                [meta + [single_end: true, file_type: 'fastq'], reads_1]
            }
        }

    // --------- Register study if accession was not provided via --submission_study
    def study_accession_ch
    if (submission_study) {
        // Use provided study accession directly
        study_accession_ch = channel.of(submission_study)
    } else {
        // Register a new study using the study metadata file
        REGISTERSTUDY(
            channel.of([[id: "study"], file(study_metadata)]),
            test_upload,
            release_date,
            center_name
        )

        study_accession_ch = REGISTERSTUDY.out.accessions
            .map { _meta, json ->
                def data = new groovy.json.JsonSlurper().parse(json)
                data.submitted[0]?.accession
            }
    }

    // --------- Generate reads manifest files
    CREATE_READS_MANIFEST(
        reads_ch,
        study_accession_ch.first()
    )

    // Prepare input for submission with manifest and read files
    submission_input = reads_ch.join(CREATE_READS_MANIFEST.out.manifest)
        .map { meta, reads, manifest ->
            [meta, reads, manifest]
        }

    // --------- Upload data to ENA
    SUBMIT (
        submission_input,
        test_upload,
        webincli_mode,
        "reads"
    )

    // Concatenate accessions into single file to publish
    CONCAT_ACCESSIONS (
        SUBMIT.out.accessions.map { _meta, file -> file }.collect().map { files -> [ [id: "reads_accessions"], files ] },
        true // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    // --------- Collect files for the MultiQC report
    // Split "ERX...,ERR..." accession column into experiment and run columns for the report
    def ch_reads_accessions_split = CONCAT_ACCESSIONS.out.file_out
        .flatMap { _meta, tsv -> tsv.readLines().drop(1).findAll { line -> line.trim() } }
        .map { line ->
            def (alias, accessions) = line.tokenize('\t') + ['']
            def accession_list = accessions.tokenize(',')*.trim()
            def experiment = accession_list.find { acc -> acc ==~ /^[EDS]RX\d+$/ } ?: ''
            def run        = accession_list.find { acc -> acc ==~ /^[EDS]RR\d+$/ } ?: ''
            "${alias}\t${experiment}\t${run}"
        }
        .collectFile(name: 'reads_accessions_split.tsv', seed: "alias\texperiment\trun", newLine: true, sort: true)
    ch_multiqc_files = ch_multiqc_files.mix(ch_reads_accessions_split)

    emit:
    multiqc_files = ch_multiqc_files // channel: files to include in the MultiQC report
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
