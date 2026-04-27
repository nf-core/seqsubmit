process GENERATE_ASSEMBLY_MANIFEST {
    tag "$meta.id"
    label 'process_single'

    container "community.wave.seqera.io/library/pip_assembly-uploader:2a65298c0161c561"

    input:
    tuple val(meta), path(assembly_fasta), path(data_csv)
    val(assembly_study)
    val(is_tpa)
    val(test_upload)

    output:
    tuple val(meta), path("${assembly_study}_upload/*.manifest") , emit: manifest
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def tpa = is_tpa ? "--tpa" : ""
    def test_flag = test_upload ? "--test" : ""
    """
    assembly_manifest \\
        --study ${assembly_study} \\
        --data ${data_csv} \\
        --assembly_study ${assembly_study} \\
        --output-dir "." \\
        ${tpa} \\
        ${test_flag} \\
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
