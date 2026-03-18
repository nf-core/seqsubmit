/*
 * ena-webin-cli wrapper script that runs ena-webin-cli and handles errors
*/
process ENA_WEBIN_CLI_WRAPPER {

    label 'process_low'
    tag "${meta.id}"
    container "quay.io/microbiome-informatics/java_mgnify-pipelines-toolkit:1.4.20"

    input:
    tuple val(meta), path(submission_item), path(manifest)
    path(webin_cli_jar)

    output:
    path "versions.yml",                        emit: versions

    script:
    def args               = task.ext.args          ?: ""
    def prefix             = task.ext.prefix        ?: "${meta.id}"
    def mode               = params.test_upload     ? "--test" : ""
    def submit_or_validate = params.webincli_submit ? "--mode submit": "--mode validate"

    """
    # change FASTA path in manifest to current workdir
    export ITEM_FULL_PATH=\$(readlink -f ${submission_item})
    sed 's|^FASTA\t.*|FASTA\t'"\${ITEM_FULL_PATH}"'|g' ${manifest} > ${prefix}_updated_manifest.manifest

    webin_cli_handler \\
      -m ${prefix}_updated_manifest.manifest \\
      --webin-cli-jar ${webin_cli_jar} \\
      ${submit_or_validate} \\
      ${mode} \\
      ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
    END_VERSIONS
    """
}
