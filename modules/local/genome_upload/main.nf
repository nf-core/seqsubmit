process GENOME_UPLOAD {
    tag "${mags_or_bins_flag}"
    label 'process_low'

    container "quay.io/biocontainers/genome-uploader:2.5.1--pyhdfd78af_1"

    input:
    path(mags)
    path(table_for_upload)
    val(mags_or_bins_flag)
    val(submission_study)
    val(centre_name)
    val(is_tpa)
    val(upload_force)
    val(test_upload)

    output:
    path "results/{MAG,bin}_upload/manifests*/*.manifest"      , emit: manifests
    path "results/{MAG,bin}_upload/ENA_backup.json"            , emit: ena_upload_backup_json
    path "results/{MAG,bin}_upload/genome_samples.xml"         , emit: upload_genome_samples
    path "results/{MAG,bin}_upload/registered_{MAGs,bins}*.tsv", emit: upload_registered_mags
    path "results/{MAG,bin}_upload/submission.xml"             , emit: upload_submission_xml
    tuple val("${task.process}"), val('genome_uploader'), eval("genome_upload --version 2>&1 | sed 's/genome_uploader //g'"), topic: versions, emit: versions_genome_uploader

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args  ?: ''
    def tpa      = is_tpa         ? "--tpa"  : ""
    def force    = upload_force   ? "--force"  : ""
    def mode     = (!test_upload) ? "--live" : ""

    """
    genome_upload \\
        -u ${submission_study} \\
        --genome_info ${table_for_upload} \\
        --centre_name ${centre_name} \\
        --${mags_or_bins_flag} \\
        ${tpa} \\
        ${force} \\
        ${mode} \\
        --out results \\
        ${args}
    """

    stub:
    """
    mkdir results/MAG_upload
    touch results/MAG_upload/ENA_backup.json
    touch results/MAG_upload/genome_samples.xml
    touch results/MAG_upload/submission.xml
    touch results/MAG_upload/registered_MAGs_test.tsv
    mkdir results/MAG_upload/manifests_test
    touch results/MAG_upload/manifests_test/test_1.manifest
    """
}
