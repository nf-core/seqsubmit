process SUBMIT_STUDY {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "quay.io/microbiome-informatics/mgnify-pipelines-toolkit:1.4.17"

    // ENA_USERNAME and ENA_PASSWORD must be set in the process environment.
    // In the pipeline, map Nextflow secrets via conf/modules.config or nextflow.config:
    //   env { ENA_USERNAME = secrets.WEBIN_ACCOUNT; ENA_PASSWORD = secrets.WEBIN_PASSWORD }

    input:
    tuple val(meta), path(study_metadata)

    output:
    tuple val(meta), path("*_accessions.json"), emit: accessions
    path "versions.yml",                        emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args   ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    submit_study.py \\
        --input ${study_metadata} \\
        --output ${prefix}_accessions.json \\
        ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mgnify-pipelines-toolkit: \$(python -c "import importlib.metadata; print(importlib.metadata.version('mgnify-pipelines-toolkit'))")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo '{"submitted":[],"duplicates":[],"modified":[],"failed":[]}' > ${prefix}_accessions.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mgnify-pipelines-toolkit: \$(python -c "import importlib.metadata; print(importlib.metadata.version('mgnify-pipelines-toolkit'))")
    END_VERSIONS
    """
}
