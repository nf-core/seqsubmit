process CREATE_ASSEMBLY_METADATA_CSV {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/31/31f1c42a25a80ebc296a0aa07d83b3f0e408f9f3c240f9375c55d9790576c1de/data' :
        'community.wave.seqera.io/library/pip_pygments:37b2b421ce07e516' }"

    input:
    tuple val(meta), path(fasta)

    output:
    tuple val(meta), path("${meta.id}_assembly_metadata.csv"), emit: csv
    path "versions.yml"                                      , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def run_accession = meta.run_accession ?: ''
    def coverage = meta.coverage ?: ''
    def assembler = meta.assembler ?: ''
    def assembler_version = meta.assembler_version ?: ''
    def sample = '' // Sample column left empty because co-assemblies are not supported

    """
    cat > ${meta.id}_assembly_metadata.csv << EOF
Runs,Coverage,Assembler,Version,Filepath,Sample
${run_accession},${coverage},${assembler},${assembler_version},${fasta.name},${sample}
EOF

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bash: \$(bash --version | head -n1 | sed 's/.*version //; s/ .*//')
    END_VERSIONS
    """

    stub:
    """
    cat > ${meta.id}_assembly_metadata.csv << EOF
Runs,Coverage,Assembler,Version,Filepath,Sample
${meta.run_accession ?: ''},${meta.coverage ?: ''},${meta.assembler ?: ''},${meta.assembler_version ?: ''},${fasta.name},
EOF

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bash: \$(bash --version | head -n1 | sed 's/.*version //; s/ .*//')
    END_VERSIONS
    """
}
