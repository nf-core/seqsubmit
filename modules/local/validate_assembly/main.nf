process VALIDATE_ASSEMBLY{

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
    path "versions.yml"                           
}
