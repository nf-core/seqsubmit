/*
 * ena-webin-cli wrapper script that runs ena-webin-cli and handles errors
*/
process ENA_WEBIN_CLI_WRAPPER {

    label 'process_low'
    tag "${meta.id}"
    // ena-webin-cli 9.0.3 + mgnify-pipelines-toolkit 1.5.1
    container "community.wave.seqera.io/library/ena-webin-cli_mgnify-pipelines-toolkit:a64d8c87ebf167ef"
    stageInMode 'copy'

    input:
    tuple val(meta), path(submission_item), path(manifest)
    val test_upload
    val webincli_mode
    val webincli_context

    output:
    tuple val(meta), path("*_accessions.tsv"),  emit: accessions
    path "versions.yml",                        emit: versions

    script:
    def args               = task.ext.args   ?: ""
    def prefix             = task.ext.prefix ?: "${meta.id}"
    def test_flag          = test_upload     ? "--test" : ""

    """
    webin_cli_handler \\
      -m ${manifest} \\
      -o ${prefix}_accessions.tsv \\
      -c ${webincli_context} \\
      --mode ${webincli_mode} \\
      ${test_flag} \\
      ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
        ena-webin-cli: \$(ena-webin-cli -version)
        mgnify-pipelines-toolkit: \$(python -c "import importlib.metadata; print(importlib.metadata.version('mgnify-pipelines-toolkit'))")
    END_VERSIONS
    """
}
