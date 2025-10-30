process REGISTERSTUDY {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "community.wave.seqera.io/library/pip_assembly-uploader:28d20c7cae062d31"

    input:
    tuple val(meta), val(study), val(center), val(library)


    output:
    tuple val(meta), env(STUDY_ID), emit: study_accession
    path "versions.yml"           , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def args2 = task.ext.args2 ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    study_xmls \\
        $args \\
        --study ${study} \\
        --library ${library} \\
        --center ${center} \\


    submit_study \\
        $args2 \\
        --directory ${study}_upload \\
        --study ${study} 2>&1 | tee report.log

    STUDY_ID=\$(grep 'A new study accession has been created' report.log | grep -oE '(PRJ|ERP)[[:alnum:]_]+[[:digit:]]+')

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        assembly_uploader: \$(study_xmls --version)
    END_VERSIONS
    """

    stub:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.report

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        assembly_uploader: \$(study_xmls --version)
    END_VERSIONS
    """
}
