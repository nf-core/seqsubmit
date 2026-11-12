/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { COVERM_CONTIG                         } from '../modules/nf-core/coverm/contig/main'
include { CREATE_ASSEMBLY_METADATA_CSV          } from '../modules/local/create_assembly_metadata_csv/main'
include { REGISTER_COASSEMBLY_SAMPLE            } from '../modules/local/register_coassembly_sample/main'
include { GENERATE_ASSEMBLY_MANIFEST            } from '../modules/local/generate_assembly_manifest/main'
include { REGISTERSTUDY                         } from '../modules/local/registerstudy/main'
include { ENA_WEBIN_CLI_WRAPPER as SUBMIT       } from '../modules/local/ena_webin_cli_wrapper'

include { FIND_CONCATENATE as CONCAT_METADATA   } from '../modules/nf-core/find/concatenate/main'
include { FIND_CONCATENATE as CONCAT_ACCESSIONS } from '../modules/nf-core/find/concatenate/main'

include { FASTA_VALIDATION                      } from '../subworkflows/local/fasta_validation/main'
include { calculateCoassemblyCoverage           } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

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
    webincli_mode        // val: either 'validate' or 'submit' to specify WebinCLI mode of operation
    is_private           // val: fetch metadata from private/public account
    release_date         // val: keep submitted data private until given date
    center_name          // val: name of submitting institution

    main:

    def ch_multiqc_files = channel.empty()

    // --------- Create assembly channel with proper metadata structure
    assembly_fasta = ch_samplesheet
        .map { meta, fasta, _reads_1, reads_2 ->
            // support semicolon-separated values for co-assemblies (e.g. ERR000001;ERR000002)
            def run_accessions = meta.run_accession.split(';')?.toList()?.unique() ?: []
            def new_meta = meta + [
                single_end: !reads_2,
                run_accession: run_accessions.size() == 1 ? run_accessions[0] : run_accessions
            ]
            [new_meta, fasta]
        }

    // --------- Create reads channel with proper metadata structure
    reads_fastq = ch_samplesheet
        .filter { row -> row[2] && row[2] != "" } // Check if fastq_1 exists and is not empty
        .map { meta, _fasta, reads_1, reads_2 ->
            // support semicolon-separated values for co-assemblies (e.g. ERR000001;ERR000002)
            def run_accessions = meta.run_accession.split(';')?.toList()?.unique() ?: []
            def new_meta = meta + [
                single_end: !reads_2,
                run_accession: run_accessions.size() == 1 ? run_accessions[0] : run_accessions
            ]

            def fastq1_list = reads_1.toString().split(';').toList()
            def fastq2_list = reads_2 ? reads_2.toString().split(';').toList() : []

            // Validation: Check that number of read files matches number of accessions
            if (run_accessions.size() > 1) {
                if (fastq1_list.size() != run_accessions.size()) {
                    error "Sample ${new_meta.id}: Number of forward read files (${fastq1_list.size()}) does not match number of run accessions (${run_accessions.size()})"
                }
                if (fastq2_list && fastq2_list.size() != run_accessions.size()) {
                    error "Sample ${new_meta.id}: Number of reverse read files (${fastq2_list.size()}) does not match number of run accessions (${run_accessions.size()}). Coverage cannot be calculated for co-assemblies mixing single-end and paired-end runs: provide 'coverage' in the samplesheet instead"
                }
            }

            // Convert paths to file objects
            def fastq1_paths = fastq1_list.collect { path -> file(path.trim(), checkIfExists: true) }
            def fastq2_paths = fastq2_list ? fastq2_list.collect { path -> file(path.trim(), checkIfExists: true) } : []

            if (fastq2_paths) {
                [new_meta, fastq1_paths, fastq2_paths]
            } else {
                [new_meta, fastq1_paths]
            }
        }

    // --------- Check fasta files are properly formatted and filter out files with less than 2 contigs
    FASTA_VALIDATION (
        assembly_fasta
    )

    // --------- Assembly coverage calculation
    // For assemblies without coverage, calculate coverage with CoverM
    coverm_input = FASTA_VALIDATION.out.valid_fastas
        .filter { meta, _fasta -> !(meta.coverage) }
        .join(reads_fastq)
        .map { tuple ->
            def meta = tuple[0]
            def fasta = tuple[1]
            def reads_data = tuple[2..-1]

            // Transform reads into flat list for CoverM
            def all_reads = []
            if (meta.single_end) {
                // Single-end: just flatten the R1 list
                def fastq1_list = reads_data[0]
                all_reads = fastq1_list
            } else {
                // Paired-end: interleave R1 and R2 files
                // Input format: [meta, [R1_1, R1_2, ...], [R2_1, R2_2, ...]]
                def fastq1_list = reads_data[0]
                def fastq2_list = reads_data[1]

                // Create list as: R1_1, R2_1, R1_2, R2_2, ...
                // Use collectMany to flatten the pairs
                all_reads = [fastq1_list, fastq2_list].transpose().collectMany { pair -> pair }
            }

            [meta, fasta, all_reads]
        }
        .multiMap { meta, fasta, reads ->
            assembly: [ meta, fasta ]
            reads: [ meta, reads ]
        }

    COVERM_CONTIG (
        coverm_input.reads,
        coverm_input.assembly,
        false, // bam_input
        false, // interleaved
        false  // enable_bam_output
    )

    // Length-weighted co-assembly coverage (see docs/methods.md)
    average_coverage_ch = COVERM_CONTIG.out.coverage
        .map { meta, coverage_tsv ->
            [ meta, calculateCoassemblyCoverage(coverage_tsv) ]
        }

    // Update metadata with calculated coverage
    assemblies_with_added_cov_ch = FASTA_VALIDATION.out.valid_fastas
        .filter { meta, _fasta -> meta.coverage == null }
        .join( average_coverage_ch )
        .map { meta, fasta, avg_coverage ->
            def updated_meta = meta.clone()
            updated_meta.coverage = avg_coverage
            [updated_meta, fasta]
        }

    // Combine assemblies with updated metadata (for samples that had coverage calculated)
    // and assemblies that already had coverage
    assemblies_with_coverage = FASTA_VALIDATION.out.valid_fastas
        .filter { meta, _fasta -> meta.coverage != null }
        .mix( assemblies_with_added_cov_ch )

    // --------- Create CSV with assembly metadata for manifest generation
    CREATE_ASSEMBLY_METADATA_CSV(
        assemblies_with_coverage
    )

    // For co-assemblies (multiple run accessions), register a virtual ENA sample and fill Sample column.
    // Rows with a single run accession bypass this step unchanged.
    assembly_metadata_by_type = CREATE_ASSEMBLY_METADATA_CSV.out.csv
        .branch { meta, _csv ->
            coassembly: meta.run_accession instanceof List && meta.run_accession.size() > 1
            individual_assembly: true
        }

    REGISTER_COASSEMBLY_SAMPLE(
        assembly_metadata_by_type.coassembly,
        test_upload,
        is_private
    )

    assembly_metadata_with_sample = assembly_metadata_by_type.individual_assembly
        .mix(REGISTER_COASSEMBLY_SAMPLE.out.csv)

    // --------- Concatenate assembly metadata CSVs into single file to publish
    CONCAT_METADATA (
        assembly_metadata_with_sample.map { _meta, file -> file }.collect().map { files -> [ [id: "assemblies_metadata"], files ] },
        'true' // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    // --------- Register study if accession was not provided via --submission_study
    def study_accession_ch
    if (submission_study) {
        // Use provided study accession directly
        study_accession_ch = channel.of(submission_study)
    } else {
        // Register a new study using the study metadata file
        REGISTERSTUDY(
            // Only register a study when at least one assembly passed validation
            FASTA_VALIDATION.out.valid_fastas.first().map { _it -> [[id: "study"], file(study_metadata)] },
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

    // --------- Generate assembly manifest files and submit them to ENA
    GENERATE_ASSEMBLY_MANIFEST(
        assemblies_with_coverage.join(assembly_metadata_with_sample),
        study_accession_ch.first(),
        upload_tpa,
        test_upload,
        is_private
    )

    // --------- Upload data to ENA
    SUBMIT (
        assemblies_with_coverage.join(GENERATE_ASSEMBLY_MANIFEST.out.manifest),
        test_upload,
        webincli_mode,
        "genome"
    )

    // Concatenate accessions into single file to publish
    CONCAT_ACCESSIONS (
        SUBMIT.out.accessions.map { _meta, file -> file }.collect().map { files -> [ [id: "assemblies_accessions"], files ] },
        'true' // skip_header - we want to keep the header from the first file and skip it for the rest
    )

    // --------- Collect files for the MultiQC report
    ch_multiqc_files = ch_multiqc_files.mix(CONCAT_ACCESSIONS.out.file_out.map{_meta, file -> file})
    // Convert metadata CSVs to TSV for MultiQC: the Runs column of co-assemblies holds
    // quoted comma-separated accessions (e.g. "SRR3183850,SRR3183951"), which MultiQC splits.
    // MultiQC uses the first column as row key, so prepend the unique assembly ID
    // (Runs alone is not unique and duplicate rows would be merged)
    def ch_assembly_metadata_tsv = assembly_metadata_with_sample
        .flatMap { meta, csv ->
            csv.readLines().drop(1).findAll { line -> line.trim() }.collect { line ->
                // split on commas outside double quotes, then strip the quotes
                def fields = line.split(/,(?=(?:[^"]*"[^"]*")*[^"]*$)/, -1)
                    .collect { field -> field.trim().replaceAll(/^"|"$/, '') }
                ([meta.id] + fields).join('\t')
            }
        }
        .collectFile(
            name: 'assemblies_metadata.tsv',
            seed: "Assembly\tRuns\tCoverage\tAssembler\tVersion\tFilepath\tSample\tLibrary",
            newLine: true,
            sort: true
        )
    ch_multiqc_files = ch_multiqc_files.mix(ch_assembly_metadata_tsv)

    emit:
    multiqc_files = ch_multiqc_files // channel: files to include in the MultiQC report
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
