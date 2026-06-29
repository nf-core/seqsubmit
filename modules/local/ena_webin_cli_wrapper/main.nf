/*
 * ena-webin-cli wrapper script that runs ena-webin-cli and handles errors
*/
process ENA_WEBIN_CLI_WRAPPER {

    label 'process_low'
    tag "${meta.id}"

    conda "${moduleDir}/environment.yml"

    // ena-webin-cli 9.0.3 + mgnify-pipelines-toolkit 1.5.1
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/90/907aee7f61eca630e96a0f50d1bd71d9ba8ac9ca10da02459221930c21076a2a/data':
        'community.wave.seqera.io/library/ena-webin-cli_mgnify-pipelines-toolkit:a64d8c87ebf167ef' }"
    stageInMode 'copy'

    input:
    tuple val(meta), path(submission_item), path(manifest)
    val test_upload
    val webincli_mode
    val webincli_context

    output:
    tuple val(meta), path("*_accessions.tsv"),     emit: accessions,    optional: true // there is no file in mode=validate
    tuple val("${task.process}"), val('python'), eval('python --version 2>&1 | sed "s/Python //g"'), topic: versions
    tuple val("${task.process}"), val('ena-webin-cli'), eval('ena-webin-cli -version'),              topic: versions
    tuple val("${task.process}"), val('mgnify-pipelines-toolkit'), eval('python -c "import importlib.metadata; print(importlib.metadata.version(\'mgnify-pipelines-toolkit\'))"'), topic: versions

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
    """
}
