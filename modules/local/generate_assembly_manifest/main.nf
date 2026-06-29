process GENERATE_ASSEMBLY_MANIFEST {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/assembly_uploader:1.3.5--pyhdfd78af_1':
        'quay.io/biocontainers/assembly_uploader:1.3.5--pyhdfd78af_1' }"

    input:
    tuple val(meta), path(assembly_fasta), path(data_csv)
    val(assembly_study)
    val(is_tpa)
    val(test_upload)
    val(is_private)

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
    def is_private_flag = is_private ? "--private" : ""
    """
    assembly_manifest \\
        --study ${assembly_study} \\
        --data ${data_csv} \\
        --assembly_study ${assembly_study} \\
        --output-dir "." \\
        ${tpa} \\
        ${test_flag} \\
        ${is_private_flag} \\
        ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        assembly_uploader: \$(assembly_manifest --version | sed 's/assembly_uploader //')
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
        assembly_uploader: \$(assembly_manifest --version | sed 's/assembly_uploader //')
    END_VERSIONS
    """
}
