/*
 * ena-webin-cli wrapper script that runs ena-webin-cli and handles errors
*/
process ENA_WEBIN_CLI_WRAPPER {

    label 'process_low'
    tag "${meta.id}"
    // ena-webin-cli 9.0.3 + mgnify-pipelines-toolkit 1.4.24
    container "community.wave.seqera.io/library/ena-webin-cli_mgnify-pipelines-toolkit:0fd318932c5ba88e"
    stageInMode 'copy'

    input:
    tuple val(meta), path(submission_item), path(manifest)
    val test_upload
    val webincli_mode

    output:
    tuple val(meta), path("*_accessions.tsv"),  emit: accessions
    path "versions.yml",                        emit: versions

    script:
    def args               = task.ext.args   ?: ""
    def prefix             = task.ext.prefix ?: "${meta.id}"
    def test_flag          = test_upload     ? "--test" : ""
    def fasta_dir          = submission_item.toRealPath().parent

    """
    webin_cli_handler \\
      -m ${manifest} \\
      -o ${prefix}_accessions.tsv \\
      --mode ${webincli_mode} \\
      --fasta-dir ${fasta_dir} \\
      ${test_flag} \\
      ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
    END_VERSIONS
    """
}
