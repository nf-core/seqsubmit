process ENA_WEBIN_CLI {
    tag "$meta.id"
    label 'process_low'

    container "quay.io/biocontainers/ena-webin-cli:9.0.1--hdfd78af_1"

    stageInMode 'copy'
    if (!params.webincli_mock) {
        secret 'WEBIN_ACCOUNT'
        secret 'WEBIN_PASSWORD'
    }

    input:
    tuple val(meta), path(submission_item), path(manifest)

    output:
    tuple val(meta), path("*webin-cli.report"), emit: webin_report
    tuple val(meta), env('STATUS')            , emit: upload_status
    path "versions.yml"                       , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix             = task.ext.prefix        ?: "${meta.id}"
    def mode               = params.test_upload     ? "-test" : ""
    def submit_or_validate = params.webincli_submit ? "-submit": "-validate"
    def webincli_mock      = params.webincli_mock   ? "true" : "false"

    """
    # change FASTA path in manifest to current workdir
    export ITEM_FULL_PATH=\$(readlink -f ${submission_item})
    sed 's|^FASTA\t.*|FASTA\t'"\${ITEM_FULL_PATH}"'|g' ${manifest} > ${prefix}_updated_manifest.manifest

    if [[ "${webincli_mock}" == "true" ]]; then
        if [[ "${submit_or_validate}" == "-submit" ]]; then
            cat <<-EOF > webin-cli.report
            INFO : MOCK WEBIN RUN
            INFO : command=ena-webin-cli -context=genome -manifest=${prefix}_updated_manifest.manifest ${submit_or_validate} ${mode}
            INFO : Submission(s) validated successfully
            INFO : The submission has been completed successfully
            INFO : This was a TEST submission(s)
            EOF
        else
            cat <<-EOF > webin-cli.report
            INFO : MOCK WEBIN RUN
            INFO : command=ena-webin-cli -context=genome -manifest=${prefix}_updated_manifest.manifest ${submit_or_validate} ${mode}
            INFO : Submission(s) validated successfully
            EOF
        fi
    else
        ena-webin-cli \\
            -context=genome \\
            -manifest=${prefix}_updated_manifest.manifest \\
            -userName="\${WEBIN_ACCOUNT}" \\
            -password="\${WEBIN_PASSWORD}" \\
            ${submit_or_validate} \\
            ${mode}
    fi

    mv webin-cli.report "${prefix}_webin-cli.report"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ena-webin-cli: \$(ena-webin-cli -version 2>&1 )
    END_VERSIONS

    # status check
    if grep -q "submission has been completed successfully" "${prefix}_webin-cli.report"; then
        # first time submission completed successfully
        export STATUS="success"
        true
    elif grep -q "object being added already exists in the submission account with accession" "${prefix}_webin-cli.report"; then
        # there was attempt to re-submit already submitted genome
        export STATUS="success"
        true
    elif grep -q "Submission(s) validated successfully" "${prefix}_webin-cli.report"; then
        # we ran with -validate flag
        export STATUS="success"
        true
    else
        export STATUS="failed"
        false
    fi
    """
}
