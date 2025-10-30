process GENERATE_ASSEMBLY_MANIFEST {
    tag "$meta.id"
    label 'process_single'

    container "community.wave.seqera.io/library/pip_assembly-uploader:28d20c7cae062d31"

    input:
    tuple val(meta), path(assembly_fasta), path(data_csv)
    val(assembly_study)

    output:
    tuple val(meta), path("${assembly_study}_upload/*.manifest") , emit: manifest
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    assembly_manifest \\
        --study ${assembly_study} \\
        --data ${data_csv} \\
        --assembly_study ${assembly_study} \\
        --output-dir "." \\
        ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        assembly_uploader: \$(assembly_manifest --version)
    END_VERSIONS
    """

    stub:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir ${assembly_study}_upload/
    touch ${assembly_study}_upload/test.manifest

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        assembly_uploader: \$(assembly_manifest --version)
    END_VERSIONS
    """
}
