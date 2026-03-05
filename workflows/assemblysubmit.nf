/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { COVERM_CONTIG              } from '../modules/nf-core/coverm/contig/main'
include { FASTAVALIDATOR             } from '../modules/nf-core/fastavalidator/main'
include { GENERATE_ASSEMBLY_MANIFEST } from '../modules/local/generate_assembly_manifest/main'
include { REGISTERSTUDY              } from '../modules/local/registerstudy/main'
include { ENA_WEBIN_CLI              } from '../modules/local/ena_webin_cli'

include { MULTIQC                    } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap           } from 'plugin/nf-schema'
include { paramsSummaryMultiqc       } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML     } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText     } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN THE WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow ASSEMBLYSUBMIT {

    take:
    ch_samplesheet // channel: samplesheet read in from --assemblies_samplesheet

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
        "true" // is_metagenome flag
    )
    // TODO add some logging here to track discarded assemblies
    validated_fastas = assembly_fasta.join(FASTAVALIDATOR.out.success_log)
        .map { meta, fasta, _log ->
            [meta, fasta]
        }

    // TODO add human decontamination step

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

    // Calculate average coverage using map operator
    average_coverage_ch = COVERM_CONTIG.out.coverage
        .map { meta, coverage_file ->
            // Read the file and calculate average
            def lines = coverage_file.readLines()
            def coverages = lines[1..-1].collect { line -> 
                line.split('\t')[1] as Double 
            }
            def average = coverages.sum() / coverages.size()
            return [meta, average]
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
        .view( { meta, _fasta -> 
            "Sample ${meta.id}: Final coverage = ${meta.coverage}" 
        } )

    // TODO add validation step to check number of lines in CSV matches number of assemblies

    assembly_metadata_csv = assemblies_with_coverage
        .map { meta, fasta ->
            def header = 'Runs,Coverage,Assembler,Version,Filepath,Sample'
            def row = [
                meta.run_accession ?: '',
                meta.coverage ?: '',
                meta.assembler ?: '',
                meta.assembler_version ?: '',
                fasta.name,
                ''    // Sample column left empty because co assemblies are not supported
            ].join(',')
            
            def content = "${header}\n${row}"
            def csv_file = file("${meta.id}_assembly_metadata.csv")
            csv_file.text = content
            
            [meta, csv_file]
        }

    // TODO only register study if it's not provided
    REGISTERSTUDY(
        [[id:"study"], params.ena_raw_reads_study_accession, params.centre_name, params.library ]
    )

    // Generate assembly manifest files and submit them to ENA
    GENERATE_ASSEMBLY_MANIFEST(
        assemblies_with_coverage.join(assembly_metadata_csv),
        REGISTERSTUDY.out.study_accession.map { _meta, accession -> accession }
    )
    
    ENA_WEBIN_CLI(
        validated_fastas.join(GENERATE_ASSEMBLY_MANIFEST.out.manifest)
    )

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
