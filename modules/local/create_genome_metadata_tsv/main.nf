process CREATE_GENOME_METADATA_TSV {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'oras://community.wave.seqera.io/library/bash:5.2.37--06dbc4169cb39ae0' :
        'community.wave.seqera.io/library/bash:5.2.37--ae00789afb795adf' }"

    input:
    tuple val(meta), path(fasta)

    output:
    tuple val(meta), path("${meta.id}_genome_metadata.tsv"), emit: tsv
    tuple val("${task.process}"), val('bash'), eval('bash --version | head -n1 | sed "s/.*version //; s/ .*//"'), topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def co_assembly_value = meta.co_assembly == 'Yes' ? 'True' : 'False'
    def rna_presence_value = meta.RNA_presence == 'Yes' ? 'True' : 'False'
    def header = [
        'genome_name',
        'genome_path',
        'accessions',
        'assembly_software',
        'binning_software',
        'binning_parameters',
        'stats_generation_software',
        'completeness',
        'contamination',
        'genome_coverage',
        'metagenome',
        'co-assembly',
        'broad_environment',
        'local_environment',
        'environmental_medium',
        'rRNA_presence',
        'NCBI_lineage'
    ].join('\t')
    def row = [
        meta.id,
        fasta.name,
        meta.accession,
        meta.assembly_software,
        meta.binning_software,
        meta.binning_parameters,
        meta.stats_generation_software,
        meta.completeness,
        meta.contamination,
        meta.genome_coverage,
        meta.metagenome,
        co_assembly_value,
        meta.broad_environment,
        meta.local_environment,
        meta.environmental_medium,
        rna_presence_value,
        meta.NCBI_lineage
    ].join('\t')
    """
    cat <<-END_TSV > ${meta.id}_genome_metadata.tsv
    ${header}
    ${row}
    END_TSV
    """

    stub:
    """
    touch ${meta.id}_genome_metadata.tsv
    """
}
