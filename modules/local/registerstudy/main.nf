process REGISTERSTUDY {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    // TODO: this still points at the old mgnify-pipelines-toolkit image,
    // which does NOT have ena-submission-toolkit/ena-api-client/linkml-lib
    // installed (see environment.yml — submit_study.py no longer depends on
    // mgnify-pipelines-toolkit at all). Conda profile works as-is; docker/
    // singularity profiles need a new container image built from
    // environment.yml's pip dependencies before this module will run under
    // those engines.
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
        ena-submission-toolkit: \$(python -c "import importlib.metadata; print(importlib.metadata.version('ena-submission-toolkit'))")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo '{"submitted":[],"failed":[]}' > ${prefix}_accessions.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ena-submission-toolkit: \$(python -c "import importlib.metadata; print(importlib.metadata.version('ena-submission-toolkit'))")
    END_VERSIONS
    """
}
