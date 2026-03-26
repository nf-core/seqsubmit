/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { GENOME_UPLOAD as CREATE_MANIFESTS } from '../modules/local/genome_upload'
include { ENA_WEBIN_CLI_WRAPPER as SUBMIT   } from '../modules/local/ena_webin_cli_wrapper'
include { ENA_WEBIN_CLI_DOWNLOAD            } from '../modules/local/ena_webin_cli_download'
include { REGISTERSTUDY                     } from '../modules/local/registerstudy/main'
include { RENAME_FASTA_FOR_CATPACK          } from '../modules/local/rename_fasta_for_catpack'

include { FASTAVALIDATOR                    } from '../modules/nf-core/fastavalidator/main'
include { COVERM_GENOME                     } from '../modules/nf-core/coverm/genome'
include { MULTIQC                           } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap                  } from 'plugin/nf-schema'

include { GENOME_EVALUATION                 } from '../subworkflows/local/genome_evaluation'
include { RNA_DETECTION                     } from '../subworkflows/local/rna_detection'
include { FASTA_CLASSIFY_CATPACK            } from '../subworkflows/nf-core/fasta_classify_catpack/main'

include { paramsSummaryMultiqc              } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML            } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText            } from '../subworkflows/local/utils_nfcore_seqsubmit_pipeline'

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

    ch_versions = channel.empty()
    ch_multiqc_files = channel.empty()

     // --------- Create genomes channel with proper metadata structure
    genome_fasta_and_reads = ch_samplesheet
        .map { row ->
            def meta = [
                id: row[0].id,
                accession: row[2],
                single_end: row[4] ? false : true,
                assembly_software: row[5] ?: null,
                binning_software: row[6] ?: null,
                binning_parameters: row[7] ?: null,
                stats_generation_software: row[8] ?: null,
                completeness: row[9] ?: null,
                contamination: row[10] ?: null,
                genome_coverage: row[11] ?: null,
                metagenome: row[12] ?: null,
                co_assembly: row[13] ?: null,
                broad_environment: row[14] ?: null,
                local_environment: row[15] ?: null,
                environmental_medium: row[16] ?: null,
                RNA_presence: row[17] ?: null,
                NCBI_lineage: row[18] ?: null
            ]
            def read1 = row[3] ? file(row[3]) : null
            def read2 = row[4] ? file(row[4]) : null

            if (row[4] && row[4] != "") {
                // If paired end reads
                return [meta, file(row[1]), [read1, read2]]
            } else {
                // If single end
                return [meta, file(row[1]), [read1]]
            }
        }

    genome_fasta = genome_fasta_and_reads.map{meta, fasta, _fq1 -> [meta, fasta]}
    genome_reads = genome_fasta_and_reads.map{meta, _fasta, reads -> [meta, reads]}

    // --------- Check fasta files are properly formatted
    FASTAVALIDATOR (
        genome_fasta,
        "true" // enables number of contigs check - ENA requires more than 1 contig for a bin/MAG submission
    )
    validated_fastas = genome_fasta.join(FASTAVALIDATOR.out.success_log)
        .map { meta, fasta, _log ->
            [meta, fasta]
        }

    // --------- Genome coverage calculation
    validated_fastas
        .branch { meta, _fasta ->
            genome_coverage_ref_input: meta.genome_coverage == null
            genome_coverage_present: true  // Everything else goes here
        }
    .set { branched_coverage_results }

    branched_coverage_results.genome_coverage_ref_input.join(genome_reads)
        .multiMap { meta, fasta, fastq ->
            genome: [ meta, fasta ]
            raw_reads: [ meta, fastq ]
        }
        .set { coverm_input }

    COVERM_GENOME (
        coverm_input.raw_reads,
        coverm_input.genome,
        false,
        false,
        'file'
    )
    ch_versions = ch_versions.mix( COVERM_GENOME.out.versions )

    // Update metadata for records missing coverage
    fasta_updated_with_coverage = COVERM_GENOME.out.coverage.join(branched_coverage_results.genome_coverage_ref_input)
        .map{ meta, coverage_tsv, fasta ->
              def coverage = coverage_tsv.readLines()[1].split('\t')[1];  // skip header
              def updated_meta = meta.clone()
              updated_meta.genome_coverage = coverage;
              return [updated_meta, fasta]
        }
        .mix(branched_coverage_results.genome_coverage_present)

    // --------- For genomes without RNA_presence info, calculate rRNA and tRNA
    fasta_updated_with_coverage
        .branch { meta, fasta ->
            rna_prediction_input: meta.RNA_presence == null
            rna_present: true  // Everything else goes here
        }
    .set { branched_rna_results }

    RNA_DETECTION (
        branched_rna_results.rna_prediction_input
    )
    ch_versions = ch_versions.mix( RNA_DETECTION.out.versions )

    // Update metadata for records missing RNA
    fasta_updated_with_rna = RNA_DETECTION.out.rna_detected.join(branched_rna_results.rna_prediction_input)
        .map{ meta, rna_decision, fasta ->
              def decision = rna_decision.readLines()[0].split('\t')[1];
              def updated_meta = meta.clone()
              updated_meta.RNA_presence = decision;
              return [updated_meta, fasta]
        }
        .mix(branched_rna_results.rna_present)

    // --------- Completeness and contamination calculation
    fasta_updated_with_rna
        .branch { meta, fasta ->
            genome_evaluation_input: meta.completeness == null || meta.contamination == null || meta.stats_generation_software == null
            evaluation_present: true  // Everything else goes here
        }
    .set { branched_stats_results }

    GENOME_EVALUATION (
        branched_stats_results.genome_evaluation_input
    )

    // Create a value channel with the version string
    def stats_version_ch = GENOME_EVALUATION.out.stats_versions
        .map { _process_name, tool_name, version_output -> return "${tool_name}_v${version_output}"
        }.first()

    fasta_updated_with_stats = GENOME_EVALUATION.out.genome_evaluation
        .join(branched_stats_results.genome_evaluation_input)
        .combine(stats_version_ch)
        .map { meta, stats_tsv, fasta, stats_version ->
            def line = stats_tsv.readLines()[1].split('\t')
            def updated_meta = meta.clone()
            updated_meta.completeness = line[1]
            updated_meta.contamination = line[2]
            updated_meta.stats_generation_software = stats_version

            return [updated_meta, fasta]
        }
        .mix(branched_stats_results.evaluation_present)

    // --------- Taxonomy
    fasta_updated_with_stats
        .branch { meta, fasta ->
            genome_taxonomy_input: meta.NCBI_lineage == null
            taxonomy_present: true  // Everything else goes here
        }
    .set { branched_taxonomy_results }

    // Change extension for all files required taxonomy to .fasta because CATPACK requires suffix as input
    RENAME_FASTA_FOR_CATPACK (
        branched_taxonomy_results.genome_taxonomy_input
    )

    // build input structures for CAT_DB depending on what provided as input
    def cat_db_input = params.cat_db
        ? channel.of( [['id': 'CAT_DB'], file(params.cat_db)] )
        : channel.empty()

    def cat_db_id_input = (!params.cat_db && params.cat_db_download_id)
        ? channel.of( [['id': 'CAT_DB_id'], params.cat_db_download_id] )
        : channel.empty()

    FASTA_CLASSIFY_CATPACK (
        RENAME_FASTA_FOR_CATPACK.out.renamed_fasta,  // ch_bins
        channel.empty(),                             // ch_contigs - empty because we classify bins, not contigs
        cat_db_input,
        cat_db_id_input,
        false,                                       // disable summary generation
        '.fasta'                                     // bin_suffix - the suffix of the renamed fasta files
    )

    fasta_updated_with_taxonomy = FASTA_CLASSIFY_CATPACK.out.bat_classification
        .join(branched_taxonomy_results.genome_taxonomy_input)
        .map { meta, taxa_tsv, fasta ->
            def line = taxa_tsv.readLines()[1].split('\t')
            def updated_meta = meta.clone()
            updated_meta.NCBI_lineage = line[3]
            return [updated_meta, fasta]
        }
        .mix(branched_taxonomy_results.taxonomy_present)

    // --------- Combine metadata into TSV
    genome_metadata_csv = fasta_updated_with_taxonomy
        .map { meta, fasta ->
            [
                meta.id,
                fasta.getName(),
                meta.accession,
                meta.assembly_software,
                meta.binning_software,
                meta.binning_parameters,
                meta.stats_generation_software,
                meta.completeness,
                meta.contamination,
                meta.genome_coverage,
                meta.metagenome,
                meta.co_assembly == "Yes" ? "True" : "False",
                meta.broad_environment,
                meta.local_environment,
                meta.environmental_medium,
                meta.RNA_presence == "Yes" ? "True" : "False",
                meta.NCBI_lineage
            ].join('\t')
        }
        .collectFile(
            name: 'genomes_metadata.csv',
            storeDir: "${params.outdir}/${params.mode}",
            seed: [
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
                'NCBI_lineage'
            ].join('\t'),
            newLine: true
        )

    // --------- Register study if accession not provided
    def study_accession_ch
    if (params.submission_study) {
        study_accession_ch = channel.of(params.submission_study)
    } else {
        REGISTERSTUDY(
            channel.of([[id: "study"], file(params.study_metadata)])
        )
        ch_versions = ch_versions.mix(REGISTERSTUDY.out.versions)
        study_accession_ch = REGISTERSTUDY.out.accessions
            .map { _meta, json ->
                def data = new groovy.json.JsonSlurper().parse(json)
                data.submitted[0]?.accession
            }
    }

    // --------- Generate manifests
    CREATE_MANIFESTS(
        fasta_updated_with_stats.map{meta, fasta -> fasta}.collect(),
        genome_metadata_csv,
        params.mode,     // mags or bins
        study_accession_ch.first()
    )

    // All manifests were generated in one run
    // Manifests should be separated into different channels using prefix as id
    manifests_ch = CREATE_MANIFESTS.out.manifests.flatten()
        .map { manifest ->
            def prefix = params.test_upload ?
                manifest.name.replaceAll(/_\d+\.manifest$/, '') :  // Remove extension and hash suffix appended in test mode
                manifest.name.replaceAll(/\.manifest$/, '')        // Remove only extension in live mode
            def meta = [id: prefix]
            [ meta, manifest ]
    }
    // Combine fasta and manifests
    ch_combined = fasta_updated_with_stats
    .map { meta, fasta -> [meta.id, meta, fasta] }
    .join(
        manifests_ch.map { meta, manifest -> [meta.id, manifest] }  // Has only [id: prefix]
    )
    .map { id, full_meta, fasta, manifest ->
        [full_meta, fasta, manifest]
    }

    // --------- Upload data to ENA
    ENA_WEBIN_CLI_DOWNLOAD (
        params.webin_cli_version
    )

    SUBMIT (
        ch_combined,
        ENA_WEBIN_CLI_DOWNLOAD.out.webin_cli_jar
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
