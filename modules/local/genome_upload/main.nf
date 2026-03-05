process GENOME_UPLOAD {
    tag "$meta.id"
    label 'process_low'

    container "community.wave.seqera.io/library/pip_genome-uploader:e2815984bcdc3e83"

    secret 'WEBIN_ACCOUNT'
    secret 'WEBIN_PASSWORD'

    input:
    tuple val(meta), path(mags)
    path(table_for_upload)
    val(mags_or_bins_flag)

    output:
    path "results/{MAG,bin}_upload/manifests*/*.manifest"      , emit: manifests
    path "results/{MAG,bin}_upload/ENA_backup.json"            , emit: ena_upload_backup_json
    path "results/{MAG,bin}_upload/genome_samples.xml"         , emit: upload_genome_samples
    path "results/{MAG,bin}_upload/registered_{MAGs,bins}*.tsv", emit: upload_registered_mags
    path "results/{MAG,bin}_upload/submission.xml"             , emit: upload_submission_xml
    path "versions.yml"                                        , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args         ?: ''
    def tpa      = params.upload_tpa     ? "--tpa"  : ""
    def force    = params.upload_force   ? "--force"  : ""
    def mode     = (!params.test_upload) ? "--live" : ""

    """
    export ENA_WEBIN=\$WEBIN_ACCOUNT
    export ENA_WEBIN_PASSWORD=\$WEBIN_PASSWORD

    genome_upload \\
        -u $params.ena_genome_study_accession \\
        --genome_info ${table_for_upload} \\
        --centre_name $params.centre_name \\
        --${mags_or_bins_flag} \\
        ${tpa} \\
        ${force} \\
        ${mode} \\
        --out results \\
        ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        genome_uploader: \$(genome_upload --version 2>&1 | sed 's/genome_uploader //g')
    END_VERSIONS
    """
}
