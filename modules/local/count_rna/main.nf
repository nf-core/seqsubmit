/*
 * Calculate number of tRNA and rRNA detected
*/
process COUNT_RNA {

    label 'process_low'
    tag "${meta.id}"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/biopython:1.75':
        'quay.io/biocontainers/biopython:1.75' }"

    input:
    tuple val(meta), path(trnas_stats), path(rrna_gff)

    output:
    tuple val(meta), path("*rna_decision.tsv"), emit: rna_decision
    path "versions.yml",                        emit: versions

    script:
    """
    count_rna.py \\
        --trna ${trnas_stats} \\
        --rrna ${rrna_gff} \\
        --name ${meta.id} \\
        --trna-limit ${params.trna_limit} \\
        --rrna-limit ${params.rrna_limit} \\
        --output ${meta.id}_rna_decision.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
    END_VERSIONS
    """

    stub:
    """
    echo -e "genome\tYes" > ${meta.id}_rna_decision.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | sed 's/Python //g')
    END_VERSIONS
    """
}
