process RENAME_FASTA_FOR_CATPACK {
    tag "${meta.id}"

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'oras://community.wave.seqera.io/library/bash:5.2.37--06dbc4169cb39ae0' :
        'community.wave.seqera.io/library/bash:5.2.37--ae00789afb795adf' }"

    input:
    tuple val(meta), path(fasta)

    output:
    tuple val(meta), path("output/*.fasta"), emit: renamed_fasta
    tuple val("${task.process}"), val('bash'), eval('bash --version | head -n1 | sed "s/.*version //; s/ .*//"'), topic: versions


    script:
        def is_compressed = fasta.name.endsWith('.gz')
        extension = '.fasta'
        def base = fasta.name
            .replaceAll(/\.gz$/, '')
            .replaceAll(/\.(fa|fasta|fna)$/, '')
        def output_name = base + extension

        if (is_compressed) {
            """
            mkdir -p output
            gunzip -c ${fasta} > output/${output_name}
            """
        } else {
            """
            mkdir -p output
            ln -s ../${fasta} output/${output_name}
            """
        }
}
