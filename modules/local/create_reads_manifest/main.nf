process CREATE_READS_MANIFEST {
    tag "$meta.id"
    label 'process_single'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'oras://community.wave.seqera.io/library/bash:5.2.37--06dbc4169cb39ae0' :
        'community.wave.seqera.io/library/bash:5.2.37--ae00789afb795adf' }"

    input:
    tuple val(meta), path(fastq_files)
    val(study_accession)
    val(test_upload)

    output:
    tuple val(meta), path("${meta.id}.manifest"), emit: manifest

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def fastq_list = fastq_files instanceof List ? fastq_files : [fastq_files]
    def fastq_entries = fastq_list.collect { "FASTQ\t${it.name}" }.join('\n')
    def insert_size_line = meta.insert_size ? "INSERT_SIZE\t${meta.insert_size}\n" : ""
    def library_name_line = meta.library_name ? "LIBRARY_NAME\t${meta.library_name}\n" : ""
    def description_line = meta.description ? "DESCRIPTION\t${meta.description}\n" : ""

    """
    cat > ${meta.id}.manifest <<'EOF'
STUDY	${study_accession}
SAMPLE	${meta.sample_accession}
NAME	${meta.id}
PLATFORM	${meta.platform}
INSTRUMENT	${meta.instrument}
LIBRARY_SOURCE	${meta.library_source}
LIBRARY_SELECTION	${meta.library_selection}
LIBRARY_STRATEGY	${meta.library_strategy}
${insert_size_line}${library_name_line}${description_line}${fastq_entries}
EOF
    """

    stub:
    """
    touch ${meta.id}.manifest
    """
}
