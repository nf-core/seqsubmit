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

    output:
    tuple val(meta), path("*_updated.csv"), emit: csv
    path "versions.yml",                    emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def test_arg = test ? "--test" : ""
    """
    register_coassembly_sample.py \\
        --input ${csv} \\
        --output ${prefix}_updated.csv \\
        ${test_arg} \\
        ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version | sed 's/Python //')
        requests: \$(python -c "import requests; print(requests.__version__)")
        retry: \$(python -c "import importlib.metadata as m; print(m.version('retry'))")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    cp ${csv} ${prefix}_updated.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version | sed 's/Python //')
        requests: \$(python -c "import requests; print(requests.__version__)")
        retry: \$(python -c "import importlib.metadata as m; print(m.version('retry'))")
    END_VERSIONS
    """
}
