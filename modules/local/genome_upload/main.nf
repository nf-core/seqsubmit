process GENOME_UPLOAD {
    tag "${mags_or_bins_flag}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/genome-uploader:3.0.4--pyhdfd78af_0':
        'quay.io/biocontainers/genome-uploader:3.0.4--pyhdfd78af_0' }"

    input:
    path(mags)   // required for validation
    path(table_for_upload)
    val(mags_or_bins_flag)
    val(submission_study)
    val(centre_name)
    val(is_tpa)
    val(test_upload)
    val(is_private)

    output:
    path "results/{MAG,bin}_upload/manifests*/*.manifest"      , emit: manifests
    path "results/{MAG,bin}_upload/ENA_backup.json"            , emit: ena_upload_backup_json
    path "results/{MAG,bin}_upload/genome_samples.xml"         , emit: upload_genome_samples
    path "results/{MAG,bin}_upload/registered_{MAGs,bins}*.tsv", emit: upload_registered_mags
    tuple val("${task.process}"), val('genome_uploader'), eval("genome_upload --version 2>&1 | sed 's/genome_uploader //g'"), topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args  ?: ''
    def tpa      = is_tpa         ? "--tpa"  : ""
    def mode     = (!test_upload) ? "--live" : ""
    def is_private_flag  = is_private   ? "--private" : ""

    """
    genome_upload \\
        -u ${submission_study} \\
        --genome_info ${table_for_upload} \\
        --centre_name "${centre_name}" \\
        --${mags_or_bins_flag} \\
        ${tpa} \\
        ${mode} \\
        ${is_private_flag} \\
        --out results \\
        ${args}
    """

    stub:
    """
    mkdir -p results/MAG_upload
    touch results/MAG_upload/ENA_backup.json
    touch results/MAG_upload/genome_samples.xml
    touch results/MAG_upload/submission.xml
    touch results/MAG_upload/registered_MAGs_test.tsv
    mkdir results/MAG_upload/manifests_test
    touch results/MAG_upload/manifests_test/test_1.manifest
    """
}
