process REGISTER_COASSEMBLY_SAMPLE {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'oras://community.wave.seqera.io/library/pip_requests_retry:d07e257656d938ab' :
        'community.wave.seqera.io/library/pip_requests_retry:eb16563fc2cb641f' }"

    input:
    tuple val(meta), path(csv)
    val(test)
    val(is_private)

    output:
    tuple val(meta), path("*_updated.csv"), emit: csv
    tuple val("${task.process}"), val('python'), eval('python --version 2>&1 | sed "s/Python //g"'), topic: versions
    tuple val("${task.process}"), val('requests'), eval('python -c "import requests; print(requests.__version__)"'), topic: versions
    tuple val("${task.process}"), val('retry'), eval('python -c "import importlib.metadata; print(importlib.metadata.version(\'retry\'))"'), topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def test_arg = test ? "--test" : ""
    def private_arg = is_private ? "--private" : ""
    """
    register_coassembly_sample.py \\
        --input ${csv} \\
        --output ${prefix}_updated.csv \\
        ${test_arg} \\
        ${private_arg} \\
        ${args}
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    cp ${csv} ${prefix}_updated.csv
    """
}
