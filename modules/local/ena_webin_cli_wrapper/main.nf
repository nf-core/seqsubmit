/*
 * ena-webin-cli wrapper script that runs ena-webin-cli and handles errors
*/
process ENA_WEBIN_CLI_WRAPPER {

    label 'process_low'
    tag "${meta.id}"
    container "community.wave.seqera.io/library/ena-webin-cli_mgnify-pipelines-toolkit:0fd318932c5ba88e"
    stageInMode 'copy'

    input:
    tuple val(meta), path(submission_item), path(manifest)
    path(webin_cli_jar)
    val test_upload
    val webincli_mode

    output:
    tuple val(meta), path("*_accessions.tsv"),  emit: accessions
    path("*_accessions_mqc.tsv"),               emit: accessions_multiqc
    path "versions.yml",                        emit: versions

    script:
    def args               = task.ext.args   ?: ""
    def prefix             = task.ext.prefix ?: "${meta.id}"
    def test_flag          = test_upload     ? "--test" : ""

    """
    # change FASTA path in manifest to current workdir
    export ITEM_FULL_PATH=\$(readlink -f ${submission_item})
    sed 's|^FASTA\t.*|FASTA\t'"\${ITEM_FULL_PATH}"'|g' ${manifest} > ${prefix}_updated_manifest.manifest

    webin_cli_handler \\
      -m ${prefix}_updated_manifest.manifest \\
      -o ${prefix}_accessions.tsv \\
      --webin-cli-jar ${webin_cli_jar} \\
      --mode ${webincli_mode} \\
      ${test_flag} \\
      ${args}

    cp ${prefix}_accessions.tsv ${prefix}_accessions_mqc.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
    END_VERSIONS
    """
}
