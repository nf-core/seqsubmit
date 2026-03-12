/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { GENOME_UPLOAD          } from '../modules/local/genome_upload'
include { ENA_WEBIN_CLI          } from '../modules/local/ena_webin_cli'
include { SUBMIT_RAWREADS_STUDY  } from '../modules/local/submit_rawreads_study/main'

include { RNA_DETECTION           } from '../subworkflows/local/rna_detection'

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

    ch_versions = channel.empty()
    ch_multiqc_files = channel.empty()

     // Create genomes channel with proper metadata structure
    genome_fasta = ch_samplesheet
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
            [meta, file(row[1])]
        }

    // For genomes without RNA_presence info, calculate rRNA and tRNA
    genome_fasta.filter { meta, fasta -> meta.RNA_presence == null }
        .map { meta, fasta -> [meta, fasta] }
        .set { rna_prediction_input }
    genome_fasta.filter { meta, fasta -> meta.RNA_presence != null }
        .map { meta, fasta -> [meta, fasta] }
        .set { rna_present }

    RNA_DETECTION (
        rna_prediction_input
    )
    ch_versions = ch_versions.mix( RNA_DETECTION.out.versions )

    // Update metadata for records missing RNA
    fasta_updated_with_rna = RNA_DETECTION.out.rna_detected.join(rna_prediction_input)
        .map{ meta, rna_decision, fasta ->
              def decision = rna_decision.readLines()[0].split('\t')[1];
              def updated_meta = meta.clone()
              updated_meta.RNA_presence = decision;
              return [updated_meta, fasta]
        }
        .mix(rna_present)


    // Combine metadata into TSV
     genome_metadata_csv = fasta_updated_with_rna
        .map { meta, fasta ->
            def row = [
                meta.id,
                fasta,
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
            name: "${params.outdir}/genomes_metadata.csv",
            seed: 'genome_name\tgenome_path\taccessions\tassembly_software\tbinning_software\tbinning_parameters\tstats_generation_software\tcompleteness\tcontamination\tgenome_coverage\tmetagenome\tco-assembly\tbroad_environment\tlocal_environment\tenvironmental_medium\trRNA_presence\tNCBI_lineage',
            newLine: true
        )

    def study_accession_ch
    if (params.submission_study) {
        study_accession_ch = channel.of(params.submission_study)
    } else {
        SUBMIT_RAWREADS_STUDY(
            channel.of([[id: "study"], file(params.study_metadata)])
        )
        ch_versions = ch_versions.mix(SUBMIT_RAWREADS_STUDY.out.versions)
        study_accession_ch = SUBMIT_RAWREADS_STUDY.out.accessions
            .map { _meta, json ->
                def data = new groovy.json.JsonSlurper().parse(json)
                data.submitted[0]?.accession
                    ?: data.duplicates[0]?.existing_accession
            }
    }

    GENOME_UPLOAD(
        genome_fasta.map{meta, fasta -> fasta}.collect(),
        genome_metadata_csv,
        params.mode,
        study_accession_ch.first()
    )
    ch_versions = ch_versions.mix( GENOME_UPLOAD.out.versions )

    //manifests_ch = GENOME_UPLOAD.out.manifests.flatten()
    //    .map { manifest ->
    //        def prefix = manifest.name.replaceAll(/_\d+\.manifest$/, '')
    //        def meta = [id: prefix]
    //        [ meta, manifest ]
    //}
    //combined_ch = ch_mags.join(manifests_ch)

    //ENA_WEBIN_CLI( combined_ch )
    //ch_versions = ch_versions.mix( ENA_WEBIN_CLI.out.versions.first() )

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
