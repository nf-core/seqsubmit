process RENAME_FASTA_FOR_CATPACK {
    tag "${meta.id}"

    input:
    tuple val(meta), path(fasta)

    output:
    tuple val(meta), path("output/*.fasta{,.gz}"), emit: renamed_fasta

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
