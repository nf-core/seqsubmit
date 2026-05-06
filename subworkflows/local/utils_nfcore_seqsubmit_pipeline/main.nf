//
// Subworkflow with functionality specific to the nf-core/seqsubmit pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { samplesheetToList         } from 'plugin/nf-schema'
include { paramsHelp                } from 'plugin/nf-schema'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { imNotification            } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW TO INITIALISE PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    input             //  string: Path to input samplesheet
    mode              //  string: Type of input data (mags, bins, metagenomic_assemblies)
    help              // boolean: Display help message and exit
    help_full         // boolean: Show the full help message
    show_hidden       // boolean: Show hidden parameters in the help message

    main:

    ch_versions = channel.empty()

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    before_text = """
-\033[2m----------------------------------------------------\033[0m-
                                        \033[0;32m,--.\033[0;30m/\033[0;32m,-.\033[0m
\033[0;34m        ___     __   __   __   ___     \033[0;32m/,-._.--~\'\033[0m
\033[0;34m  |\\ | |__  __ /  ` /  \\ |__) |__         \033[0;33m}  {\033[0m
\033[0;34m  | \\| |       \\__, \\__/ |  \\ |___     \033[0;32m\\`-._,-`-,\033[0m
                                        \033[0;32m`._,._,\'\033[0m
\033[0;35m  nf-core/seqsubmit ${workflow.manifest.version}\033[0m
-\033[2m----------------------------------------------------\033[0m-
"""
    after_text = """${workflow.manifest.doi ? "\n* The pipeline\n" : ""}${workflow.manifest.doi.tokenize(",").collect { doi -> "    https://doi.org/${doi.trim().replace('https://doi.org/','')}"}.join("\n")}${workflow.manifest.doi ? "\n" : ""}
* The nf-core framework
    https://doi.org/10.1038/s41587-020-0439-x

* Software dependencies
    https://github.com/nf-core/seqsubmit/blob/master/CITATIONS.md
"""
    command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input samplesheet.csv --outdir <OUTDIR>"

    UTILS_NFSCHEMA_PLUGIN (
        workflow,
        validate_params,
        null,
        help,
        help_full,
        show_hidden,
        before_text,
        after_text,
        command
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )

    //
    // Create channel from input file provided through params.input
    //

    if ( mode == "mags" || mode == "bins" ) {
        ch_samplesheet = channel
            .fromList(samplesheetToList(input, "${projectDir}/assets/schema_input_genome.json"))
    } else if ( mode == "metagenomic_assemblies" ) {
        ch_samplesheet = channel
            .fromList(samplesheetToList(input, "${projectDir}/assets/schema_input_assembly.json"))
    } else {
        error("No input was found. Please, point to the location of your samplesheet using --input_genome or --input_assembly")
    }

    emit:
    samplesheet = ch_samplesheet
    versions    = ch_versions
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    hook_url        //  string: hook URL for notifications
    multiqc_report  //  string: Path to MultiQC report

    main:
    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def multiqc_reports = multiqc_report.toList()

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(
                summary_params,
                email,
                email_on_fail,
                plaintext_email,
                outdir,
                monochrome_logs,
                multiqc_reports.getVal(),
            )
        }

        completionSummary(monochrome_logs)
        if (hook_url) {
            imNotification(summary_params, hook_url)
        }
    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs: https://nf-co.re/docs/usage/troubleshooting"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Validate channels from input samplesheet
//
def validateInputSamplesheet(input) {
    def (metas, fastqs) = input[1..2]

    // Check that multiple runs of the same sample are of the same datatype i.e. single-end / paired-end
    def endedness_ok = metas.collect{ meta -> meta.single_end }.unique().size == 1
    if (!endedness_ok) {
        error("Please check input samplesheet -> Multiple runs of a sample must be of the same datatype i.e. single-end or paired-end: ${metas[0].id}")
    }

    return [ metas[0], fastqs ]
}
//
// Generate methods description for MultiQC
//
def toolCitationText() {
    def mgnify_tools = [
        params.mode == "metagenomic_assemblies" ? "Manifests for metagenomic assemblies upload were created by assembly_uploader (Richardson et al. 2023)." : "",
        params.mode == "bins" || params.mode == "mags" ? "Samples registration and upload manifests generation for bins/MAGs were done by genome_uploader (Gurbich et al. 2023).": ""
    ].join(' ').trim()

    def ena_tools = [
        "Submission to ENA was done by webin-cli (David, Yuan, et al. 2025)."
    ].join(' ').trim()

    def preprocessing_tools = [
        "Input FASTA validation was done by py_fasta_validator (Edwards et al. 2023)."
    ].join(' ').trim()

    def stats_tools = [
        params.mode == "bins" || params.mode == "mags" ? "Completeness and contamination metrics was performed by CheckM2 (Chklovski et al. 2023)." : "",
        params.mode == "metagenomic_assemblies" ? "Coverage calculation for metagenomic assemblies was done by CoverM contig (Aroney et el. 2025)." : "",
        params.mode == "bins" || params.mode == "mags" ? "Coverage calculation for bins/MAGs was done by CoverM genome (Aroney et el. 2025)." : ""
    ].join(' ').trim()

    def taxonomy_tools = [
        params.mode == "bins" || params.mode == "mags" ? "Taxonomy was assigned by CAT_pack (Von Meijenfeldt et al. 2019)." : ""
    ].join(' ').trim()

    def rna_tools = [
        params.mode == "bins" || params.mode == "mags" ? "Bacterial ribosomal RNA prediction was performed by barrnap (Seemann T. 2013)." : "",
        params.mode == "bins" || params.mode == "mags" ? "Transfer RNA genes were detected by tRNAscan-SE (Chan et al. 2021)." : ""
    ].join(' ').trim()

    def postprocessing_text = "Run statistics were reported using MultiQC (Ewels et al. 2016)."

    def citation_text = [
            preprocessing_tools,
            stats_tools,
            taxonomy_tools,
            rna_tools,
            mgnify_tools,
            ena_tools,
            postprocessing_text
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    def reference_text = [
            '<li>Richardson, L., Allen, B., Baldi, G., Beracochea, M., Bileschi, M. L., Burdett, T., ... & Finn, R. D. (2023). MGnify: the microbiome sequence data analysis resource in 2023. Nucleic acids research, 51(D1), D753-D759. doi: <a href="https://doi.org/10.1093/nar/gkac1080">10.1093/nar/gkac1080</a></li>',
            '<li>Gurbich, T. A., Almeida, A., Beracochea, M., Burdett, T., Burgin, J., Cochrane, G., ... & Finn, R. D. (2023). MGnify genomes: a resource for biome-specific microbial genome catalogues. Journal of molecular biology, 435(14), 168016. doi: <a href="https://doi.org/10.1016/j.jmb.2023.168016">10.1016/j.jmb.2023.168016</a></li>',
            '<li>webin-cli: David, Y., Alisha, A., Awais, A., Rajkumar, D., Dipayan, G., Muhammad, H., ... & Ugis, S. (2026). The European Nucleotide Archive in 2025. Nucleic Acids Research, 54(D1), D120-D127. doi: <a href="https://doi.org/10.1093/nar/gkaf1295">10.1093/nar/gkaf1295</a></li>',
            '<li>Edwards, R. (2023). linsalrob/py_fasta_validator: Compressy. doi: <a href="https://doi.org/10.5281/zenodo.5002710">10.5281/zenodo.5002710</a></li>',
            '<li>Chklovski, A., Parks, D. H., Woodcroft, B. J., & Tyson, G. W. (2023). CheckM2: a rapid, scalable and accurate tool for assessing microbial genome quality using machine learning. Nature Methods, 20(8), 1203-1212. doi: <a href="https://doi.org/10.1038/s41592-023-01940-w">10.1038/s41592-023-01940-w</a></li>',
            '<li>Aroney, S. T., Newell, R. J., Nissen, J. N., Camargo, A. P., Tyson, G. W., & Woodcroft, B. J. (2025). CoverM: read alignment statistics for metagenomics. Bioinformatics, 41(4), btaf147. doi: <a href="https://doi.org/10.1093/bioinformatics/btaf147">10.1093/bioinformatics/btaf147</a></li>',
            '<li>Von Meijenfeldt, F. B., Arkhipova, K., Cambuy, D. D., Coutinho, F. H., & Dutilh, B. E. (2019). Robust taxonomic classification of uncharted microbial sequences and bins with CAT and BAT. Genome biology, 20(1), 217. doi: <a href="https://doi.org/10.1038/s41467-024-47155-1">10.1038/s41467-024-47155-1</a></li>',
            '<li>barrnap: Seemann, T. (2014). barrnap: Bacterial ribosomal RNA predictor. barrnap: Bacterial ribosomal RNA predictor. <a href="http://vicbioinformatics.com/">vicbioinformatics.com</a></li>',
            '<li>Chan, P. P., Lin, B. Y., Mak, A. J., & Lowe, T. M. (2021). tRNAscan-SE 2.0: improved detection and functional classification of transfer RNA genes. Nucleic acids research, 49(16), 9077-9096. doi: <a href="https://doi.org/10.1093/nar/gkab688">10.1093/nar/gkab688</a></li>',
            '<li>Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics , 32(19), 3047–3048. doi: <a href="https://doi.org/10.1093/bioinformatics/btw354">10.1093/bioinformatics/btw354</a></li>'
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familiar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    if (meta.manifest_map.doi) {
        // Using a loop to handle multiple DOIs
        // Removing `https://doi.org/` to handle pipelines using DOIs vs DOI resolvers
        // Removing ` ` since the manifest.doi is a string and not a proper list
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}
