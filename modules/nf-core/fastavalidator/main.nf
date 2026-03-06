process FASTAVALIDATOR {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/py_fasta_validator:0.6--py37h595c7a6_0':
        'biocontainers/py_fasta_validator:0.6--py37h595c7a6_0' }"

    input:
    tuple val(meta), path(fasta)
    val(is_metagenome)

    output:
    tuple val(meta), path('*.success.log'), emit: success_log , optional: true
    tuple val(meta), path('*.error.log')  , emit: error_log   , optional: true
    path "versions.yml"                   , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    # Ensure *.error.log file exists to append to, even if py_fasta_validator doesn't produce any errors
    touch "${prefix}.error.log"

    py_fasta_validator \\
        -f $fasta \\
        2>> "${prefix}.error.log" \\
        || echo "Errors from fasta_validate printed to ${prefix}.error.log"
    
    # One more check: count contigs. More than 1 contig required.
    echo "[INFO] Checking contig count..."

    if [ "${is_metagenome}" = true ]; then
        if [[ "${fasta}" == *.gz ]]; then
            CONTIGS=\$(zcat "${fasta}" | grep -c '^>')
        else
            CONTIGS=\$(grep  -c '^>' "${fasta}")
        fi

        echo "[INFO] Contigs detected: \${CONTIGS}"

        if [ "\${CONTIGS}" -lt 2 ]; then
            echo "[ERROR] Assembly has \${CONTIGS} contig(s)." >> "${prefix}.error.log"
            echo "[ERROR] More than one contig required." >> "${prefix}.error.log"
        fi
    
    fi

    if [ \$(cat "${prefix}.error.log" | wc -l) -gt 0 ]; then
        echo "Validation failed..."

        cat \\
            "${prefix}.error.log"
    else
        echo "Validation successful..."

        mv \\
            "${prefix}.error.log" \\
            fasta_validate.stderr

        echo "Validation successful..." \\
            > "${prefix}.success.log"
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        py_fasta_validator: \$(py_fasta_validator -v | sed 's/.* version //')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "Validation successful..." \\
        > "${prefix}.success.log"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        py_fasta_validator: \$(py_fasta_validator -v | sed 's/.* version //')
    END_VERSIONS
    """
}
