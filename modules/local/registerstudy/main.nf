process REGISTERSTUDY {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/mgnify-pipelines-toolkit:1.4.21--pyhdfd78af_0':
        'biocontainers/mgnify-pipelines-toolkit:1.4.21--pyhdfd78af_0' }"

    // ENA_WEBIN and ENA_WEBIN_PASSWORD must be set in the process environment.
    // In the pipeline, map Nextflow secrets via conf/modules.config or nextflow.config:
    //   env { ENA_WEBIN = secrets.WEBIN_ACCOUNT; ENA_WEBIN_PASSWORD = secrets.WEBIN_PASSWORD }

    input:
    tuple val(meta), path(study_metadata)
    val(test_upload)

    output:
    tuple val(meta), path("*_accessions.json"), emit: accessions
    path "versions.yml",                        emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args   ?: ''
    def prefix    = task.ext.prefix ?: "${meta.id}"
    def test_flag = test_upload     ? "--test" : ""
    """
    submit_study.py \\
        --input ${study_metadata} \\
        --output ${prefix}_accessions.json \\
        ${test_flag} \\
        ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mgnify-pipelines-toolkit: \$(python -c "import importlib.metadata; print(importlib.metadata.version('mgnify-pipelines-toolkit'))")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo '{"submitted":[],"failed":[]}' > ${prefix}_accessions.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mgnify-pipelines-toolkit: \$(python -c "import importlib.metadata; print(importlib.metadata.version('mgnify-pipelines-toolkit'))")
    END_VERSIONS
    """
}
