process CREATE_ASSEMBLY_METADATA_CSV {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'oras://community.wave.seqera.io/library/bash:5.2.37--06dbc4169cb39ae0' :
        'community.wave.seqera.io/library/bash:5.2.37--ae00789afb795adf' }"

    input:
    tuple val(meta), path(fasta)

    output:
    tuple val(meta), path("${meta.id}_assembly_metadata.csv"), emit: csv
    path "versions.yml"                                      , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def header = 'Runs,Coverage,Assembler,Version,Filepath,Sample'
    def row = [
        meta.run_accession,
        meta.coverage,
        meta.assembler,
        meta.assembler_version,
        fasta.name,
        ''    // Sample column left empty because co-assemblies are not supported
    ].join(',')
    """
    cat <<-END_CSV > ${meta.id}_assembly_metadata.csv
    ${header}
    ${row}
    END_CSV

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bash: \$(bash --version | head -n1 | sed 's/.*version //; s/ .*//')
    END_VERSIONS
    """

    stub:
    """
    touch ${meta.id}_assembly_metadata.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bash: \$(bash --version | head -n1 | sed 's/.*version //; s/ .*//')
    END_VERSIONS
    """
}
