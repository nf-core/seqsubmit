process CREATE_GENOME_METADATA_TSV {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'oras://community.wave.seqera.io/library/bash:5.2.26' :
        'community.wave.seqera.io/library/bash:5.2.26'}"

    input:
    tuple val(meta), path(fasta)

    output:
    path "*.tsv"       , emit: tsv
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: 'genomes_metadata'
    def co_assembly_value = meta.co_assembly == "Yes" ? "True" : "False"
    def rna_presence_value = meta.RNA_presence == "Yes" ? "True" : "False"
    """
    # Create header
    echo -e "genome_name\\tgenome_path\\taccessions\\tassembly_software\\tbinning_software\\tbinning_parameters\\tstats_generation_software\\tcompleteness\\tcontamination\\tgenome_coverage\\tmetagenome\\tco-assembly\\tbroad_environment\\tlocal_environment\\tenvironmental_medium\\trRNA_presence\\tNCBI_lineage" > ${prefix}.tsv

    # Add data row
    echo -e "${meta.id}\\t${fasta.getName()}\\t${meta.accession}\\t${meta.assembly_software}\\t${meta.binning_software}\\t${meta.binning_parameters}\\t${meta.stats_generation_software}\\t${meta.completeness}\\t${meta.contamination}\\t${meta.genome_coverage}\\t${meta.metagenome}\\t${co_assembly_value}\\t${meta.broad_environment}\\t${meta.local_environment}\\t${meta.environmental_medium}\\t${rna_presence_value}\\t${meta.NCBI_lineage}" >> ${prefix}.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bash: \$(bash --version | head -n 1 | sed 's/GNU bash, version //; s/ .*//')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: 'genomes_metadata'
    """
    echo -e "genome_name\\tgenome_path\\taccessions\\tassembly_software\\tbinning_software\\tbinning_parameters\\tstats_generation_software\\tcompleteness\\tcontamination\\tgenome_coverage\\tmetagenome\\tco-assembly\\tbroad_environment\\tlocal_environment\\tenvironmental_medium\\trRNA_presence\\tNCBI_lineage" > ${prefix}.tsv
    echo -e "${meta.id}\\t${fasta.getName()}\\t${meta.accession}\\t${meta.assembly_software}\\t${meta.binning_software}\\t${meta.binning_parameters}\\t${meta.stats_generation_software}\\t${meta.completeness}\\t${meta.contamination}\\t${meta.genome_coverage}\\t${meta.metagenome}\\tTrue\\t${meta.broad_environment}\\t${meta.local_environment}\\t${meta.environmental_medium}\\tTrue\\t${meta.NCBI_lineage}" >> ${prefix}.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bash: \$(bash --version | head -n 1 | sed 's/GNU bash, version //; s/ .*//')
    END_VERSIONS
    """
}
