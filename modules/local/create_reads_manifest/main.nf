process CREATE_READS_MANIFEST {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/mgnify-pipelines-toolkit:1.5.1--pyhdfd78af_1':
        'quay.io/microbiome-informatics/mgnify-pipelines-toolkit:feat-raw-reads' }"

    input:
    tuple val(meta), path(read_files)
    val(study_accession)

    output:
    tuple val(meta), path("${meta.id}.manifest"), emit: manifest
    tuple val("${task.process}"), val('mgnify-pipelines-toolkit'), eval('python -c "import importlib.metadata; print(importlib.metadata.version(\'mgnify-pipelines-toolkit\'))"'), topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args         = task.ext.args ?: ''
    def prefix       = task.ext.prefix ?: "${meta.id}"
    def read_list    = read_files instanceof List ? read_files : [read_files]
    def read_flag    = meta.file_type == 'bam' ? '--bam' : '--fastq'
    def read_args    = read_list.collect { file -> "${read_flag} ${file.name}" }.join(' \\\n        ')
    def opt_insert   = meta.insert_size  ? "--insert-size ${meta.insert_size}"      : ''
    def opt_lib_name = meta.library_name ? "--library-name '${meta.library_name}'"  : ''
    def opt_desc     = meta.description  ? "--description '${meta.description}'"    : ''

    """
    create_reads_manifest \\
        --study             ${study_accession} \\
        --sample            ${meta.sample_accession} \\
        --name              ${prefix} \\
        --platform          '${meta.platform}' \\
        --instrument        '${meta.instrument}' \\
        --library-source    '${meta.library_source}' \\
        --library-selection '${meta.library_selection}' \\
        --library-strategy  '${meta.library_strategy}' \\
        --output            ${prefix}.manifest \\
        ${read_args} \\
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
