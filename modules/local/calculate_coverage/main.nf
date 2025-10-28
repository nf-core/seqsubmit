process CALCULATE_COVERAGE {
    tag "$meta.id"
    label 'process_low'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.9' :
        'quay.io/biocontainers/python:3.9' }"

    input:
    tuple val(meta), path(fasta)

    output:
    tuple val(meta), env(COVERAGE), emit: coverage
    path "versions.yml"           , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    # Dummy coverage calculation - always returns 100500
    # In the future, this will be replaced with actual CoverM calculation

    echo "Calculating coverage for ${meta.id}..."
    echo "FASTA file: ${fasta}"

    # Set dummy coverage value
    COVERAGE=100500

    echo "Calculated coverage: \$COVERAGE"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
        coverage_calculator: "dummy-1.0"
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    COVERAGE=100500

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
        coverage_calculator: "dummy-1.0"
    END_VERSIONS
    """
}
