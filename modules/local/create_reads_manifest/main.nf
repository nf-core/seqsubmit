process CREATE_READS_MANIFEST {
    tag "$meta.id"
    label 'process_single'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/mgnify-pipelines-toolkit:1.5.1--pyhdfd78af_1':
        'biocontainers/mgnify-pipelines-toolkit:1.5.1--pyhdfd78af_1' }"

    input:
    tuple val(meta), path(fastq_files)
    val(study_accession)

    output:
    tuple val(meta), path("${meta.id}.manifest"), emit: manifest

    when:
    task.ext.when == null || task.ext.when

    script:
    def args         = task.ext.args ?: ''
    def prefix       = task.ext.prefix ?: "${meta.id}"
    def fastq_list   = fastq_files instanceof List ? fastq_files : [fastq_files]
    def fastq_args   = fastq_list.collect { "--fastq ${it.name}" }.join(' \\\n        ')
    def opt_insert   = meta.insert_size  ? "--insert-size ${meta.insert_size}"      : ''
    def opt_lib_name = meta.library_name ? "--library-name '${meta.library_name}'"  : ''
    def opt_desc     = meta.description  ? "--description '${meta.description}'"    : ''

    """
    create_reads_manifest \\
        --study             ${study_accession} \\
        --sample            ${meta.sample_accession} \\
        --name              ${prefix} \\
        --platform          ${meta.platform} \\
        --instrument        '${meta.instrument}' \\
        --library-source    ${meta.library_source} \\
        --library-selection ${meta.library_selection} \\
        --library-strategy  ${meta.library_strategy} \\
        --output            ${prefix}.manifest \\
        ${fastq_args} \\
        ${opt_insert} \\
        ${opt_lib_name} \\
        ${opt_desc} \\
        ${args}
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.manifest
    """
}
