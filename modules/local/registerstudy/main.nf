process REGISTERSTUDY {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/mgnify-pipelines-toolkit:1.5.1--pyhdfd78af_1':
        'biocontainers/mgnify-pipelines-toolkit:1.5.1--pyhdfd78af_1' }"

    // ENA_WEBIN and ENA_WEBIN_PASSWORD must be set in the process environment.
    // In the pipeline, map Nextflow secrets via conf/modules.config or nextflow.config:
    //   env { ENA_WEBIN = secrets.ENA_WEBIN; ENA_WEBIN_PASSWORD = secrets.ENA_WEBIN_PASSWORD }

    input:
    tuple val(meta), path(study_metadata)
    val(test_upload)
    val(release_date)

    output:
    tuple val(meta), path("*_accessions.json"), emit: accessions
    tuple val("${task.process}"), val('mgnify-pipelines-toolkit'), eval('python -c "import importlib.metadata; print(importlib.metadata.version(\'mgnify-pipelines-toolkit\'))"'), topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args   ?: ''
    def prefix    = task.ext.prefix ?: "${meta.id}"
    def test_flag = test_upload     ? "--test" : ""
    def hold_data_private_until = release_date ? "--hold-until ${release_date}" : ""

    """
    submit_study.py \\
        --input ${study_metadata} \\
        --output ${prefix}_accessions.json \\
        ${test_flag} \\
        ${hold_data_private_until} \\
        ${args}
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo '{"submitted":[],"failed":[]}' > ${prefix}_accessions.json
    """
}
