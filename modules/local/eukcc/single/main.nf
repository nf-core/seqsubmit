process EUKCC_SINGLE {

    tag "${meta.id}"
    label 'process_high'

    conda "${moduleDir}/environment.yml"
    container 'quay.io/biocontainers/eukcc:2.2.0--pyhdfd78af_0'

    input:
    tuple val(meta), path(fasta)
    tuple val(meta_db), path(eukcc_db)

    output:
    tuple val(meta), path("${prefix}_eukcc_results/eukcc.tsv"), emit: eukcc_tsv
    tuple val("${task.process}"), val('eukcc'), eval('eukcc -v 2>&1 | grep -oE "[0-9]+\\.[0-9]+\\.[0-9]+" | head -n1'), emit: versions_eukcc, topic: versions
    tuple val("${task.process}"), val('metaeuk'), eval('metaeuk -h 2>&1 | grep "Version" | sed "s/.*Version: //"'), emit: versions_metaeuk, topic: versions
    tuple val("${task.process}"), val('pplacer'), eval('pplacer --version'), emit: versions_pplacer, topic: versions

    script:
    def args = task.ext.args ?: ''
    prefix   = task.ext.prefix ?: "${meta.id}"

    """
    # EukCC exit codes:
    #   201 - no marker genes found, 204 - MetaEuk predicted zero proteins: not an error, genome has no estimate
    #   any other non-zero code (e.g. 1, 200, 202, 203, 222) is a real failure
    set +e
    eukcc single \\
        ${args} \\
        --db ${eukcc_db} \\
        --out ${prefix}_eukcc_results \\
        --threads ${task.cpus} \\
        ${fasta}
    exit_code=\$?
    set -e

    case \$exit_code in
        0)
            ;;
        201|204)
            # write header-only table so the genome is kept downstream with empty completeness/contamination
            echo "EukCC exited with code \$exit_code: no completeness estimate for ${prefix}" >&2
            mkdir -p ${prefix}_eukcc_results
            printf 'fasta\\tcompleteness\\tcontamination\\tncbi_lng\\n' > ${prefix}_eukcc_results/eukcc.tsv
            ;;
        *)
            echo "EukCC failed with exit code \$exit_code" >&2
            exit \$exit_code
            ;;
    esac
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir -p ${prefix}_eukcc_results
    printf 'fasta\\tcompleteness\\tcontamination\\tncbi_lng\\n${fasta}\\t90.0\\t1.0\\t1-131567-2759-33154-4751\\n' > ${prefix}_eukcc_results/eukcc.tsv
    """
}
